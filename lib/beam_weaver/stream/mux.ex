defmodule BeamWeaver.Stream.Mux do
  @moduledoc """
  Caller-owned live stream multiplexer.

  Producers run in monitored tasks and push typed stream envelopes through a
  lazy `Enumerable`. The mux owns a bounded queue, applies the configured
  backpressure policy, and cancels unresolved producers when the consumer
  halts.
  """

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Stream, as: BWStream
  alias BeamWeaver.Stream.Envelope
  alias BeamWeaver.Stream.Events
  alias BeamWeaver.Stream.Policy
  alias BeamWeaver.Stream.Sink
  alias BeamWeaver.Tracing

  defstruct producers: [],
            policy: %Policy{},
            metadata: %{},
            namespace: [],
            run_id: nil,
            graph: nil

  defmodule State do
    @moduledoc false

    defstruct mux: nil,
              tasks: %{},
              queue: :queue.new(),
              queue_size: 0,
              blocked: :queue.new(),
              heartbeat_sent?: false,
              done?: false
  end

  def new(opts \\ []) do
    policy =
      opts
      |> Keyword.take([
        :max_buffer,
        :overflow,
        :emit_timeout,
        :timeout,
        :producer_supervisor,
        :cancel_timeout,
        :heartbeat
      ])
      |> Policy.new()

    %__MODULE__{
      producers: Keyword.get(opts, :producers, []),
      policy: policy,
      metadata: Keyword.get(opts, :metadata, %{}),
      namespace: Keyword.get(opts, :namespace, []),
      run_id: Keyword.get(opts, :run_id),
      graph: Keyword.get(opts, :graph)
    }
  end

  def from_producers(producers, opts \\ []),
    do: opts |> Keyword.put(:producers, producers) |> new()

  def stream(%__MODULE__{} = mux) do
    Elixir.Stream.resource(
      fn -> start_producers(mux) end,
      &next/1,
      &cleanup/1
    )
  end

  def stream(producers, opts) when is_list(producers),
    do: producers |> from_producers(opts) |> stream()

  defp start_producers(%__MODULE__{} = mux) do
    owner = self()
    trace_context = Tracing.capture_context()

    {tasks, queue, queue_size} =
      mux.producers
      |> Enum.with_index()
      |> Enum.reduce({[], :queue.new(), 0}, fn {producer, index}, {tasks, queue, size} ->
        spec = normalize_producer(producer, index)
        token = make_ref()

        sink = %Sink{
          owner: owner,
          token: token,
          name: spec.name,
          emit_timeout: mux.policy.emit_timeout,
          metadata: mux.metadata,
          namespace: mux.namespace
        }

        task = start_task(mux, spec, sink, trace_context)

        task_info =
          {task.pid,
           %{
             task: task,
             name: spec.name,
             token: token,
             sink: sink,
             started_at: System.monotonic_time(:millisecond)
           }}

        {queue, size} = queue_in(queue, size, debug_event(mux, spec.name, :producer_start))

        {[task_info | tasks], queue, size}
      end)

    %State{
      mux: mux,
      tasks: Map.new(tasks),
      queue: queue,
      queue_size: queue_size,
      blocked: :queue.new(),
      heartbeat_sent?: false,
      done?: false
    }
  end

  defp next(%{done?: true} = state), do: {:halt, state}

  defp next(%{queue_size: size} = state) when size > 0 do
    {event, state} = queue_out(state)
    state = release_blocked(state)
    {[event], state}
  end

  defp next(%{mux: mux} = state) do
    if map_size(state.tasks) == 0 and :queue.is_empty(state.blocked) do
      {:halt, %{state | done?: true}}
    else
      receive do
        {:beam_weaver_mux_emit, token, ref, pid, name, item} ->
          state =
            if task_token?(state.tasks, pid, token) do
              enqueue_item(state, ref, pid, name, item, %{})
            else
              send(pid, {:beam_weaver_mux_ack, ref, {:error, cancelled_error()}})
              state
            end

          next(state)

        {:beam_weaver_mux_emit, token, ref, pid, name, item, emit_opts} ->
          state =
            if task_token?(state.tasks, pid, token) do
              enqueue_item(state, ref, pid, name, item, emit_opts)
            else
              send(pid, {:beam_weaver_mux_ack, ref, {:error, cancelled_error()}})
              state
            end

          next(state)

        {:beam_weaver_mux_done, pid, :ok} ->
          {event, state} = finish_task(state, pid, :ok)
          {[event], state}

        {:beam_weaver_mux_done, pid, {:error, error}} ->
          {event, state} = finish_task(state, pid, {:error, error})
          {[event], state}

        {:DOWN, ref, :process, pid, reason} ->
          case pop_task_by_ref(state, ref, pid) do
            {nil, new_state} ->
              {[], new_state}

            {task_info, new_state} ->
              event =
                BWStream.envelope(%Events.Error{error: normalize_exit(reason)},
                  run_id: mux.run_id,
                  graph: mux.graph,
                  node: task_info.name,
                  namespace: mux.namespace,
                  metadata: mux.metadata
                )

              {[event], new_state}
          end
      after
        heartbeat_timeout(mux) ->
          handle_timeout(state)
      end
    end
  end

  defp cleanup(%{tasks: tasks} = state) do
    Enum.each(tasks, fn {_pid, %{task: task, token: token}} ->
      send(task.pid, {:beam_weaver_mux_cancel, token})
      Task.shutdown(task, state.mux.policy.cancel_timeout)
    end)

    BWStream.emit(:cancel, %{count: map_size(tasks)}, %{})
    :ok
  end

  defp enqueue_item(%{mux: mux} = state, ref, pid, name, item, emit_opts) do
    item = normalize_item(mux, name, item, emit_opts)

    if queue_room?(state, mux.policy) do
      send(pid, {:beam_weaver_mux_ack, ref, :ok})
      queue_in(state, item)
    else
      handle_overflow(state, ref, pid, name, item)
    end
  end

  defp handle_overflow(%{mux: %{policy: %{overflow: :block}} = mux} = state, ref, pid, name, item) do
    blocked = :queue.in({ref, pid, name, item}, state.blocked)
    event = debug_event(mux, name, :backpressure_wait)

    state
    |> Map.put(:blocked, blocked)
    |> maybe_append_debug(event, mux.policy)
  end

  defp handle_overflow(%{mux: mux} = state, ref, pid, name, _item)
       when mux.policy.overflow == :drop_newest do
    send(pid, {:beam_weaver_mux_ack, ref, {:dropped, :newest}})
    event = debug_event(mux, name, :backpressure_drop, %{dropped: :newest})
    maybe_append_debug(state, event, mux.policy)
  end

  defp handle_overflow(%{mux: mux, queue_size: size} = state, ref, pid, name, item)
       when mux.policy.overflow == :drop_oldest and size > 0 do
    max_buffer = mux.policy.max_buffer
    send(pid, {:beam_weaver_mux_ack, ref, :ok})
    event = debug_event(mux, name, :backpressure_drop, %{dropped: :oldest})

    state
    |> queue_drop_oldest()
    |> queue_in(event)
    |> queue_in(item)
    |> queue_trim_to(max_buffer)
  end

  defp handle_overflow(%{mux: mux} = state, ref, pid, name, _item)
       when mux.policy.overflow == :drop_oldest do
    send(pid, {:beam_weaver_mux_ack, ref, {:dropped, :newest}})
    event = debug_event(mux, name, :backpressure_drop, %{dropped: :newest})
    maybe_append_debug(state, event, mux.policy)
  end

  defp handle_overflow(%{mux: mux} = state, ref, pid, name, _item) do
    error = Error.new(:stream_backpressure, "stream buffer is full")
    send(pid, {:beam_weaver_mux_ack, ref, {:error, error}})
    event = debug_event(mux, name, :backpressure_error)
    maybe_append_debug(state, event, mux.policy)
  end

  defp release_blocked(%{blocked: blocked, mux: mux} = state) do
    cond do
      not queue_room?(state, mux.policy) ->
        state

      :queue.is_empty(blocked) ->
        state

      true ->
        {{:value, {ref, pid, _name, item}}, blocked} = :queue.out(blocked)
        send(pid, {:beam_weaver_mux_ack, ref, :ok})

        state
        |> Map.put(:blocked, blocked)
        |> queue_in(item)
    end
  end

  defp maybe_append_debug(state, event, %{max_buffer: 0}), do: queue_in(state, event)

  defp maybe_append_debug(%{queue_size: size} = state, _event, %{max_buffer: max})
       when size >= max, do: state

  defp maybe_append_debug(state, event, _policy), do: queue_in(state, event)

  defp handle_timeout(%{mux: mux} = state) do
    case mux.policy.heartbeat do
      %{interval_ms: interval} when is_integer(interval) and interval > 0 ->
        {[debug_event(mux, nil, :heartbeat, mux.policy.heartbeat.payload)], %{state | heartbeat_sent?: true}}

      _other ->
        event =
          envelope(mux, %Events.Error{
            error: Error.new(:stream_timeout, "stream producer timed out")
          })

        cleanup(state)
        {[event], %{state | tasks: %{}, done?: true}}
    end
  end

  defp finish_task(%{mux: mux} = state, pid, result) do
    {task_info, tasks} = Map.pop(state.tasks, pid)

    if task_info, do: Process.demonitor(task_info.task.ref, [:flush])

    event =
      case result do
        :ok -> debug_event(mux, task_info && task_info.name, :producer_stop)
        {:error, error} -> error_event(mux, task_info && task_info.name, error)
      end

    state = %{state | tasks: tasks} |> release_blocked()

    if heartbeat_due_on_finish?(mux, task_info, state) do
      heartbeat =
        debug_event(mux, task_info.name, :heartbeat, mux.policy.heartbeat.payload)

      state =
        state
        |> queue_in(event)
        |> Map.put(:heartbeat_sent?, true)

      {heartbeat, state}
    else
      {event, state}
    end
  end

  defp heartbeat_due_on_finish?(
         %{policy: %{heartbeat: %{interval_ms: interval}}},
         %{started_at: started_at},
         %{heartbeat_sent?: false}
       )
       when is_integer(interval) and interval > 0 do
    System.monotonic_time(:millisecond) - started_at >= interval
  end

  defp heartbeat_due_on_finish?(_mux, _task_info, _state), do: false

  defp pop_task_by_ref(state, ref, pid) do
    case Map.pop(state.tasks, pid) do
      {nil, tasks} ->
        task =
          Enum.find_value(tasks, fn {task_pid, %{task: task} = info} ->
            if task.ref == ref, do: {task_pid, info}, else: nil
          end)

        case task do
          nil -> {nil, state}
          {task_pid, info} -> {info, %{state | tasks: Map.delete(tasks, task_pid)}}
        end

      {info, tasks} ->
        {info, %{state | tasks: tasks}}
    end
  end

  defp queue_room?(%{queue_size: size}, %{max_buffer: max}), do: size < max

  defp queue_in(queue, size, item), do: {:queue.in(item, queue), size + 1}

  defp queue_in(%{queue: queue, queue_size: size} = state, item) do
    {queue, size} = queue_in(queue, size, item)
    %{state | queue: queue, queue_size: size}
  end

  defp queue_out(%{queue: queue, queue_size: size} = state) do
    {{:value, item}, queue} = :queue.out(queue)
    {item, %{state | queue: queue, queue_size: max(size - 1, 0)}}
  end

  defp queue_drop_oldest(%{queue: queue, queue_size: size} = state) when size > 0 do
    {{:value, _item}, queue} = :queue.out(queue)
    %{state | queue: queue, queue_size: size - 1}
  end

  defp queue_trim_to(%{queue_size: size} = state, max_size) when size > max_size do
    state
    |> queue_drop_oldest()
    |> queue_trim_to(max_size)
  end

  defp queue_trim_to(state, _max_size), do: state

  defp start_task(%__MODULE__{policy: %{producer_supervisor: nil}}, spec, sink, trace_context) do
    Task.async(fn -> Tracing.attach_context(trace_context, fn -> run_producer(spec, sink) end) end)
  end

  defp start_task(%__MODULE__{policy: %{producer_supervisor: supervisor}}, spec, sink, trace_context) do
    Task.Supervisor.async_nolink(supervisor, fn ->
      Tracing.attach_context(trace_context, fn -> run_producer(spec, sink) end)
    end)
  end

  defp run_producer(spec, %Sink{} = sink) do
    result =
      try do
        case spec.mode do
          :sink -> spec.fun.(sink)
          :emit_fun -> spec.fun.(fn item -> Sink.emit(sink, item) end)
        end
      rescue
        exception ->
          {:error,
           Error.new(:stream_error, Exception.message(exception), %{
             exception: inspect(exception.__struct__)
           })}
      catch
        kind, reason ->
          {:error,
           Error.new(:stream_error, "stream producer exited", %{
             kind: kind,
             reason: inspect(reason)
           })}
      end

    send(sink.owner, {:beam_weaver_mux_done, self(), normalize_result(result)})
  end

  defp normalize_producer({:sink, name, fun}, _index) when is_function(fun, 1),
    do: %{mode: :sink, name: name, fun: fun}

  defp normalize_producer({:sink, fun}, index) when is_function(fun, 1),
    do: %{mode: :sink, name: "producer_#{index}", fun: fun}

  defp normalize_producer({name, fun}, _index) when is_function(fun, 1),
    do: %{mode: :emit_fun, name: name, fun: fun}

  defp normalize_producer(fun, index) when is_function(fun, 1),
    do: %{mode: :emit_fun, name: "producer_#{index}", fun: fun}

  defp debug_event(mux, name, type, extra \\ %{}) do
    envelope(mux, %Events.Debug{payload: Map.merge(%{type: type}, extra)}, node: name)
  end

  defp error_event(mux, name, error) do
    envelope(mux, %Events.Error{error: error}, node: name)
  end

  defp envelope(mux, event, opts \\ []) do
    BWStream.envelope(event,
      run_id: mux.run_id,
      graph: mux.graph,
      node: Keyword.get(opts, :node),
      namespace: mux.namespace,
      metadata: mux.metadata
    )
  end

  defp normalize_item(mux, name, %Envelope{} = envelope, emit_opts) do
    namespace = Map.get(emit_opts, :namespace, envelope.namespace)
    metadata = Map.get(emit_opts, :metadata, %{})

    %{
      envelope
      | run_id: envelope.run_id || mux.run_id,
        graph: envelope.graph || mux.graph,
        node: envelope.node || name,
        timestamp: envelope.timestamp || System.system_time(:microsecond),
        namespace: if(envelope.namespace in [nil, []], do: namespace || [], else: envelope.namespace),
        metadata: Map.merge(metadata || %{}, envelope.metadata || %{})
    }
  end

  defp normalize_item(mux, name, item, emit_opts) do
    BWStream.envelope(item,
      run_id: mux.run_id,
      graph: mux.graph,
      node: name,
      namespace: Map.get(emit_opts, :namespace, mux.namespace),
      metadata: Map.merge(mux.metadata || %{}, Map.get(emit_opts, :metadata, %{}) || %{})
    )
  end

  defp normalize_result(result) when result in [:ok, nil], do: :ok
  defp normalize_result({:ok, _result}), do: :ok
  defp normalize_result({:error, %Error{} = error}), do: {:error, error}

  defp normalize_result({:error, reason}),
    do: {:error, Error.new(:stream_error, "stream producer failed", %{reason: inspect(reason)})}

  defp normalize_result(_result), do: :ok

  defp normalize_exit(:normal), do: cancelled_error()

  defp normalize_exit(reason),
    do: Error.new(:stream_error, "stream producer exited", %{reason: inspect(reason)})

  defp cancelled_error, do: Error.new(:stream_cancelled, "stream producer was cancelled")

  defp heartbeat_timeout(%__MODULE__{policy: %{heartbeat: %{interval_ms: interval}}})
       when is_integer(interval) and interval > 0,
       do: interval

  defp heartbeat_timeout(%__MODULE__{policy: %{timeout: timeout}}), do: timeout

  defp task_token?(tasks, pid, token) do
    case Map.get(tasks, pid) do
      %{token: ^token} ->
        true

      _other ->
        Enum.any?(tasks, fn {_task_pid, %{token: task_token}} -> task_token == token end)
    end
  end
end
