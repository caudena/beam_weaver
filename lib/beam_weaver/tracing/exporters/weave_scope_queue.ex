defmodule BeamWeaver.Tracing.Exporters.WeaveScope.Config do
  @moduledoc false

  use BeamWeaver.Provider.RedactedInspect

  defstruct api_key: nil,
            endpoint: nil,
            version: nil,
            otp_app: :beam_weaver,
            transport: Req,
            batch_size: 200,
            flush_interval: 250,
            max_items: 100_000,
            max_batch_bytes: 6_000_000,
            max_inflight: 2,
            overflow: :block,
            retry_delay: 100,
            backoff: 2.0,
            jitter: 0.0,
            max_attempts: 5,
            shutdown: 120_000,
            redactor: &BeamWeaver.Tracing.Redactor.redact/1

  def new(opts) do
    fields = for {key, default} <- Map.from_struct(%__MODULE__{}), do: {key, Keyword.get(opts, key, default)}
    struct!(__MODULE__, fields)
  end
end

defmodule BeamWeaver.Tracing.Exporters.WeaveScope.Queue do
  @moduledoc """
  Supervised async native WeaveScope exporter queue.

  The queue owns batching, retries, overflow behavior, dead letters, redaction,
  and telemetry. Uploads run outside the queue process in bounded concurrent
  batches, so producers only wait if the larger in-memory buffer actually fills.
  Rejections returned by
  WeaveScope are terminal because they represent invalid payload events, not
  transient transport failures.

  When the queue stops, for example when the application shuts down, it
  uploads the observations still pending, retrying failed uploads, for up to
  its `:shutdown` time (120 seconds by default) less one second.
  """

  use GenServer

  @behaviour BeamWeaver.Tracing.Exporter

  require Logger

  alias BeamWeaver.Tracing.Exporters.WeaveScope
  alias BeamWeaver.Tracing.Exporters.WeaveScope.Config
  alias BeamWeaver.Tracing.Run

  defstruct queue: :queue.new(),
            waiting: :queue.new(),
            inflight: %{},
            flush_waiters: [],
            dead_letters: [],
            config: %Config{},
            backpressure_active?: false,
            draining?: false,
            retry_timer: nil

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc false
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :id, Keyword.get(opts, :name, __MODULE__)),
      start: {__MODULE__, :start_link, [opts]},
      shutdown: Config.new(opts).shutdown
    }
  end

  @impl BeamWeaver.Tracing.Exporter
  def export(event, %Run{} = run, opts) do
    queue = Keyword.get(opts, :queue, __MODULE__)
    enqueue(queue, event, run, Keyword.get(opts, :queue_opts, []))
  end

  @spec enqueue(GenServer.server(), atom(), Run.t(), keyword()) :: :ok
  def enqueue(server \\ __MODULE__, event, %Run{} = run, opts \\ []) do
    GenServer.call(server, {:enqueue, event, run, opts}, :infinity)
  end

  @spec dead_letters(GenServer.server()) :: [map()]
  def dead_letters(server \\ __MODULE__), do: GenServer.call(server, :dead_letters)

  @spec stats(GenServer.server()) :: map()
  def stats(server \\ __MODULE__), do: GenServer.call(server, :stats)

  @spec flush(GenServer.server(), timeout()) :: :ok | {:error, term()}
  def flush(server \\ __MODULE__, timeout \\ 5_000), do: GenServer.call(server, :flush, timeout)

  @spec stop(GenServer.server(), keyword()) :: :ok | {:error, term()}
  def stop(server \\ __MODULE__, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 5_000)

    with :ok <- GenServer.call(server, :flush, timeout) do
      GenServer.stop(server, Keyword.get(opts, :reason, :normal), timeout)
    end
  catch
    :exit, _reason -> {:error, :weavescope_flush_incomplete}
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    config = Config.new(opts)
    schedule_flush(config)
    {:ok, %__MODULE__{config: config}}
  end

  @impl true
  def handle_call({:enqueue, event, run, opts}, from, state) do
    item = new_item(event, redact_run(state, run), opts)

    if block_enqueue?(state) do
      unless state.backpressure_active? do
        Logger.warning("BeamWeaver WeaveScope exporter queue is full; model tracing is waiting for upload capacity")
        send(self(), :retry)
      end

      {:noreply, %{state | waiting: :queue.in({from, item}, state.waiting), backpressure_active?: true}}
    else
      state = enqueue_item(state, item)
      emit(:enqueue, state, item, %{result: :ok})

      state =
        if :queue.len(state.queue) >= state.config.batch_size or state.config.flush_interval <= 0,
          do: dispatch_due(state),
          else: state

      {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call(:flush, from, state) do
    emit(:flush_start, state, nil, %{count: pending_count(state)})
    state = %{state | flush_waiters: [from | state.flush_waiters]}
    {:noreply, state |> dispatch_due() |> finish_flush_if_drained()}
  end

  def handle_call(:dead_letters, _from, state),
    do: {:reply, Enum.reverse(state.dead_letters), state}

  def handle_call(:stats, _from, state) do
    stats = %{
      queued: :queue.len(state.queue),
      pending_items: pending_count(state),
      inflight_batches: map_size(state.inflight),
      blocked_producers: :queue.len(state.waiting),
      dead_letters: length(state.dead_letters),
      backpressure_active?: state.backpressure_active?
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_info(:retry, state),
    do: {:noreply, %{state | retry_timer: nil} |> dispatch_due() |> finish_flush_if_drained()}

  def handle_info(:flush_interval, state) do
    schedule_flush(state.config)
    {:noreply, state |> dispatch_due() |> finish_flush_if_drained()}
  end

  def handle_info({:upload_result, token, result}, state) do
    case Map.pop(state.inflight, token) do
      {nil, _inflight} ->
        {:noreply, state}

      {%{monitor: monitor, items: items}, inflight} ->
        Process.demonitor(monitor, [:flush])

        state =
          %{state | inflight: inflight}
          |> handle_upload_result(items, result)
          |> admit_waiting()

        {:noreply, state |> dispatch_due() |> finish_flush_if_drained()}
    end
  end

  def handle_info({:DOWN, monitor, :process, _pid, reason}, state) do
    case Enum.find(state.inflight, fn {_token, batch} -> batch.monitor == monitor end) do
      nil ->
        {:noreply, state}

      {token, %{items: items}} ->
        state = %{state | inflight: Map.delete(state.inflight, token)}
        Enum.each(items, &emit(:upload_failure, state, &1, %{error: inspect(reason)}))
        state = state |> retry_items(items) |> admit_waiting()
        {:noreply, state |> dispatch_due() |> finish_flush_if_drained()}
    end
  end

  # Uploads what is still pending before the queue exits. Uploads run in
  # separate processes, so their results are received here until the queue is
  # drained or the shutdown time runs out.
  @impl true
  def terminate(_reason, state) do
    deadline = drain_deadline(state.config.shutdown)
    state = drain(dispatch_due(%{state | draining?: true}), deadline)

    if not drained?(state) do
      Logger.error("BeamWeaver WeaveScope exporter stopped with #{pending_count(state)} pending observations")
    end

    :ok
  end

  defp drain(state, deadline) do
    if drained?(state) do
      state
    else
      receive do
        {:upload_result, _token, _result} = message -> drain_message(message, state, deadline)
        {:DOWN, _monitor, :process, _pid, _reason} = message -> drain_message(message, state, deadline)
      after
        remaining(deadline) -> state
      end
    end
  end

  defp drain_message(message, state, deadline) do
    {:noreply, state} = handle_info(message, state)
    drain(state, deadline)
  end

  defp schedule_flush(%Config{flush_interval: interval}) when is_integer(interval) and interval > 0,
    do: Process.send_after(self(), :flush_interval, interval)

  defp schedule_flush(_config), do: nil

  defp drained?(state) do
    :queue.is_empty(state.queue) and :queue.is_empty(state.waiting) and map_size(state.inflight) == 0
  end

  defp drain_deadline(:infinity), do: :infinity

  defp drain_deadline(shutdown) when is_integer(shutdown),
    do: System.monotonic_time(:millisecond) + max(shutdown - 1_000, 0)

  defp drain_deadline(_brutal_kill), do: System.monotonic_time(:millisecond)

  defp remaining(:infinity), do: :infinity
  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  defp enqueue_item(%__MODULE__{config: config} = state, item) do
    queue = :queue.in(item, state.queue)

    if :queue.len(queue) <= config.max_items do
      %{state | queue: queue}
    else
      apply_overflow(%{state | queue: queue})
    end
  end

  defp block_enqueue?(%__MODULE__{config: %{overflow: :block, max_items: max_items}} = state) do
    pending_count(state) >= max_items or not :queue.is_empty(state.waiting)
  end

  defp block_enqueue?(_state), do: false

  defp admit_waiting(%__MODULE__{config: %{overflow: :block, max_items: max_items}} = state)
       when is_integer(max_items) and max_items > 0 do
    if pending_count(state) < max_items do
      case :queue.out(state.waiting) do
        {{:value, {from, item}}, waiting} ->
          state = %{state | queue: :queue.in(item, state.queue), waiting: waiting}
          emit(:enqueue, state, item, %{result: :ok})
          GenServer.reply(from, :ok)
          admit_waiting(state)

        {:empty, _waiting} ->
          if state.backpressure_active? do
            Logger.info("BeamWeaver WeaveScope exporter queue recovered from backpressure")
          end

          %{state | backpressure_active?: false}
      end
    else
      state
    end
  end

  defp admit_waiting(state), do: state

  defp pending_count(state) do
    :queue.len(state.queue) +
      Enum.reduce(state.inflight, 0, fn {_token, batch}, total -> total + length(batch.items) end)
  end

  defp apply_overflow(%{config: %{overflow: overflow}} = state) when overflow in [:drop_newest, :error] do
    {{:value, newest}, queue} = :queue.out_r(state.queue)
    drop(%{state | queue: queue}, newest, if(overflow == :error, do: :queue_full, else: :dropped_newest))
  end

  defp apply_overflow(state) do
    {{:value, oldest}, queue} = :queue.out(state.queue)
    drop(%{state | queue: queue}, oldest, :dropped_oldest)
  end

  defp drop(state, item, reason) do
    emit(:drop, state, item, %{reason: reason})
    %{state | dead_letters: [Map.put(item, :reason, reason) | state.dead_letters]}
  end

  defp dispatch_due(%__MODULE__{} = state) do
    if map_size(state.inflight) >= state.config.max_inflight do
      state
    else
      due_by =
        if state.flush_waiters == [] and not state.draining?, do: System.monotonic_time(:millisecond), else: :infinity

      case take(state.queue, state.config.batch_size, due_by, state.config.max_batch_bytes) do
        {[], _queue} ->
          schedule_retry(state)

        {items, queue} ->
          %{state | queue: queue} |> start_upload(coalesce_items(items)) |> admit_waiting() |> dispatch_due()
      end
    end
  end

  defp start_upload(state, items) do
    parent = self()
    token = make_ref()
    config = state.config

    {:ok, pid} =
      Task.start(fn ->
        receive do
          :upload -> :ok
        end

        result = upload_batch(items, config)
        send(parent, {:upload_result, token, result})
      end)

    monitor = Process.monitor(pid)
    state = %{state | inflight: Map.put(state.inflight, token, %{monitor: monitor, items: items})}
    send(pid, :upload)
    state
  end

  defp upload_batch(_items, %{api_key: api_key}) when api_key in [nil, ""],
    do: {:error, :missing_weavescope_api_key}

  defp upload_batch(_items, %{endpoint: endpoint}) when endpoint in [nil, ""],
    do: {:error, :missing_weavescope_endpoint}

  defp upload_batch(items, config) do
    exportable = Enum.map(items, fn item -> {item.event, item.run, item.opts} end)

    opts =
      config
      |> Map.take([:api_key, :endpoint, :version, :otp_app, :transport])
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    WeaveScope.export_batch(exportable, opts)
  end

  defp handle_upload_result(state, items, :ok) do
    Enum.each(items, &emit(:upload_success, state, &1, %{result: :ok}))
    state
  end

  defp handle_upload_result(state, items, {:rejected, rejected}) do
    dead_letter_rejections(state, items, rejected)
  end

  defp handle_upload_result(state, items, {:error, reason}) do
    Enum.each(items, &emit(:upload_failure, state, &1, %{error: inspect(reason)}))
    retry_items(state, items)
  end

  defp schedule_retry(state) do
    if not :queue.is_empty(state.queue) and is_nil(state.retry_timer) do
      %{state | retry_timer: Process.send_after(self(), :retry, state.config.retry_delay)}
    else
      state
    end
  end

  defp finish_flush_if_drained(%{flush_waiters: []} = state), do: state

  defp finish_flush_if_drained(state) do
    if drained?(state) do
      Enum.each(state.flush_waiters, &GenServer.reply(&1, :ok))
      emit(:flush_stop, state, nil, %{result: :ok})
      %{state | flush_waiters: []}
    else
      state
    end
  end

  defp coalesce_items(items) do
    latest =
      Enum.reduce(items, %{}, fn item, latest ->
        Map.update(latest, item.run.id, item, fn existing ->
          if WeaveScope.lifecycle_rank(item.event) >= WeaveScope.lifecycle_rank(existing.event),
            do: item,
            else: existing
        end)
      end)

    items |> Enum.uniq_by(& &1.run.id) |> Enum.map(&Map.fetch!(latest, &1.run.id))
  end

  defp dead_letter_rejections(state, items, rejected) do
    rejected_by_id =
      rejected
      |> Enum.filter(&Map.get(&1, "id"))
      |> Map.new(&{Map.get(&1, "id"), &1})

    rejected_indexes =
      rejected
      |> Enum.filter(&Map.has_key?(&1, "index"))
      |> Map.new(&{Map.get(&1, "index"), &1})

    {dead, ok} =
      items
      |> Enum.with_index()
      |> Enum.split_with(fn {item, index} ->
        Map.has_key?(rejected_by_id, item.run.id) or Map.has_key?(rejected_indexes, index)
      end)

    Enum.each(ok, fn {item, _index} -> emit(:upload_success, state, item, %{result: :ok}) end)

    dead_letters =
      Enum.map(dead, fn {item, index} ->
        rejection = Map.get(rejected_by_id, item.run.id) || Map.get(rejected_indexes, index)
        emit(:upload_rejected, state, item, %{reason: Map.get(rejection, "code"), error: Map.get(rejection, "reason")})
        Map.merge(item, %{reason: :rejected, rejection: rejection})
      end)

    if dead_letters != [] do
      Logger.error("BeamWeaver WeaveScope rejected #{length(dead_letters)} observations; inspect exporter dead letters")
    end

    %{state | dead_letters: dead_letters ++ state.dead_letters}
  end

  defp retry_items(state, items) do
    now = System.monotonic_time(:millisecond)

    terminal_count =
      Enum.count(items, &(&1.attempts + 1 >= state.config.max_attempts))

    if terminal_count > 0 do
      Logger.error(
        "BeamWeaver WeaveScope exhausted retries for #{terminal_count} observations; inspect exporter dead letters"
      )
    end

    Enum.reduce(items, state, fn item, acc ->
      attempts = item.attempts + 1

      if attempts >= acc.config.max_attempts do
        emit(:dead_letter, acc, item, %{attempts: attempts, reason: :max_attempts})

        %{
          acc
          | dead_letters: [
              Map.merge(item, %{attempts: attempts, reason: :max_attempts}) | acc.dead_letters
            ]
        }
      else
        retry_at = now + retry_delay(acc.config, attempts)
        emit(:retry, acc, item, %{attempts: attempts, retry_at: retry_at})
        enqueue_item(acc, %{item | attempts: attempts, retry_at: retry_at})
      end
    end)
  end

  defp retry_delay(config, attempts) do
    base = round(config.retry_delay * :math.pow(config.backoff, max(attempts - 1, 0)))
    jitter = round(base * config.jitter * :rand.uniform())
    base + jitter
  end

  defp take(queue, count, due_by, max_bytes, bytes \\ 0, items \\ [])
  defp take(queue, 0, _due_by, _max_bytes, _bytes, items), do: {Enum.reverse(items), queue}

  defp take(queue, count, due_by, max_bytes, bytes, items) do
    with {{:value, %{retry_at: retry_at} = item}, rest} when retry_at <= due_by <- :queue.out(queue),
         size = :erlang.external_size(item),
         true <- items == [] or bytes + size <= max_bytes do
      take(rest, count - 1, due_by, max_bytes, bytes + size, [item | items])
    else
      _not_due_too_large_or_empty -> {Enum.reverse(items), queue}
    end
  end

  defp new_item(event, run, opts) do
    %{
      id: "wsq_" <> Integer.to_string(System.unique_integer([:positive, :monotonic]), 36),
      event: event,
      run: run,
      opts: opts,
      attempts: 0,
      retry_at: System.monotonic_time(:millisecond),
      enqueued_at: System.system_time(:microsecond)
    }
  end

  defp redact_run(%{config: %{redactor: redactor}}, %Run{} = run) when is_function(redactor, 1) do
    %{
      run
      | inputs: redactor.(run.inputs),
        outputs: redactor.(run.outputs),
        metadata: redactor.(run.metadata),
        context_metadata: redactor.(run.context_metadata),
        usage: redactor.(run.usage),
        error: redactor.(run.error)
    }
  end

  defp emit(operation, state, item, metadata) do
    run = item && item.run

    BeamWeaver.Telemetry.emit(
      [:beam_weaver, :weave_scope, :queue, operation],
      %{count: Map.get(metadata, :count, 1)},
      %{
        operation: operation,
        queue: self(),
        run_id: run && run.id,
        trace_id: run && run.trace_id,
        attempts: Map.get(metadata, :attempts),
        reason: Map.get(metadata, :reason),
        result: Map.get(metadata, :result),
        error: Map.get(metadata, :error),
        metadata: %{
          endpoint: state.config.endpoint,
          retry_at: Map.get(metadata, :retry_at)
        }
      }
    )
  end
end
