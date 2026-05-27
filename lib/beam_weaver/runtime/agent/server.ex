defmodule BeamWeaver.Runtime.Agent.Server do
  @moduledoc """
  Coordinator-only GenServer for agent runtime work.
  """

  use GenServer

  alias BeamWeaver.Runtime.Agent.State
  alias BeamWeaver.Runtime.Agent.StreamBroker
  alias BeamWeaver.Runtime.Agent.Work
  alias BeamWeaver.Runtime.Error
  alias BeamWeaver.Runtime.ToolRunner
  alias BeamWeaver.Tracing
  alias BeamWeaver.Tracing.Context

  @default_timeout 5_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name])
  end

  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :id, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      type: :worker
    }
  end

  @impl true
  def init(opts) do
    state = State.new(opts)

    case BeamWeaver.ProcessRegistry.register({:agent, state.id}, nil) do
      {:ok, _pid} -> {:ok, state}
      {:error, {:already_registered, _pid}} -> {:stop, {:already_registered, state.id}}
    end
  end

  @impl true
  def handle_call({:subscribe, pid}, _from, state) do
    {:reply, :ok, %{state | subscribers: StreamBroker.subscribe(state.subscribers, pid)}}
  end

  def handle_call({:unsubscribe, pid}, _from, state) do
    {:reply, :ok, %{state | subscribers: StreamBroker.unsubscribe(state.subscribers, pid)}}
  end

  def handle_call(:status, _from, state) do
    {:reply, State.status(state), state}
  end

  def handle_call({:start_work, kind, name, input, fun, opts}, _from, state) do
    case start_work(state, kind, name, input, fun, opts) do
      {:ok, work, state} -> {:reply, {:ok, work}, state}
      {:error, %Error{} = error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:cancel, work_id}, _from, state) do
    case Map.fetch(state.active_work, work_id) do
      {:ok, active} ->
        error = Error.new(:cancelled, "work was cancelled", %{work_id: work_id})
        Process.exit(active.task.pid, :kill)
        state = complete_work(state, active, {:cancelled, error})
        {:reply, :ok, state}

      :error ->
        {:reply, {:error, Error.new(:not_found, "active work not found", %{work_id: work_id})}, state}
    end
  end

  @impl true
  def handle_info({:stream_chunk, work_id, chunk}, state) do
    if Map.has_key?(state.active_work, work_id) do
      StreamBroker.broadcast(state.subscribers, state.id, {:stream, work_id, chunk})
    end

    {:noreply, state}
  end

  def handle_info({:work_timeout, work_id}, state) do
    case Map.fetch(state.active_work, work_id) do
      {:ok, active} ->
        error =
          Error.new(:timeout, "work timed out", %{work_id: work_id, timeout: active.timeout})

        Process.exit(active.task.pid, :kill)
        {:noreply, complete_work(state, active, {:failed, error})}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info({ref, result}, state) when is_reference(ref) do
    case active_by_ref(state, ref) do
      {work_id, active} ->
        Process.demonitor(ref, [:flush])
        state = complete_work(state, active, normalize_task_result(result))
        {:noreply, %{state | active_work: Map.delete(state.active_work, work_id)}}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case active_by_ref(state, ref) do
      {work_id, active} ->
        error =
          Error.new(:task_down, "work task stopped before returning", %{reason: inspect(reason)})

        state = complete_work(state, active, {:failed, error})
        {:noreply, %{state | active_work: Map.delete(state.active_work, work_id)}}

      nil ->
        {:noreply, %{state | subscribers: StreamBroker.remove_down(state.subscribers, ref)}}
    end
  end

  defp start_work(state, kind, name, input, fun, opts) do
    if is_function(fun) do
      do_start_work(state, kind, name, input, fun, opts)
    else
      {:error, Error.new(:invalid_work, "work must be a function")}
    end
  end

  defp do_start_work(state, kind, name, input, fun, opts) do
    work_id = new_work_id()
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    previous_context = Context.current()
    parent_context = Keyword.get(opts, :parent_context)

    if parent_context do
      Context.put(parent_context)
    end

    {:ok, trace_run} =
      Tracing.start_run("#{kind}: #{name}",
        kind: kind,
        inputs: input,
        tags: [:agent, kind],
        metadata: %{agent_id: state.id, work_id: work_id}
      )

    restore_context(previous_context)

    work = %Work{id: work_id, kind: kind, name: name, trace_run_id: trace_run.id}
    task_context = Context.from_run(trace_run)
    server = self()

    task =
      Task.Supervisor.async_nolink(state.task_supervisor, fn ->
        Context.attach(task_context, fn ->
          emit = fn chunk ->
            send(server, {:stream_chunk, work_id, chunk})
            :ok
          end

          ToolRunner.run(kind, fun, input, emit, opts)
        end)
      end)

    timeout_ref = timeout_ref(work_id, timeout)

    active = %{
      work: work,
      task: task,
      timeout: timeout,
      timeout_ref: timeout_ref
    }

    {:ok, work, %{state | active_work: Map.put(state.active_work, work_id, active)}}
  end

  defp complete_work(state, active, outcome) do
    cancel_timeout(active.timeout_ref)

    case outcome do
      {:completed, result} ->
        Tracing.finish_run(active.work.trace_run_id, outputs: result)
        StreamBroker.broadcast(state.subscribers, state.id, {:completed, active.work.id, result})

      {:failed, %Error{} = error} ->
        Tracing.fail_run(active.work.trace_run_id, error)
        StreamBroker.broadcast(state.subscribers, state.id, {:failed, active.work.id, error})

      {:cancelled, %Error{} = error} ->
        Tracing.fail_run(active.work.trace_run_id, error)
        StreamBroker.broadcast(state.subscribers, state.id, {:cancelled, active.work.id, error})
    end

    completed = %{
      work: active.work,
      outcome: outcome
    }

    %{
      state
      | active_work: Map.delete(state.active_work, active.work.id),
        completed_work: Map.put(state.completed_work, active.work.id, completed)
    }
  end

  defp normalize_task_result({:ok, result}), do: {:completed, result}
  defp normalize_task_result({:error, %Error{} = error}), do: {:failed, error}

  defp normalize_task_result(other) do
    {:failed,
     Error.new(:invalid_task_result, "work task returned an invalid result", %{
       result: inspect(other)
     })}
  end

  defp active_by_ref(state, ref) do
    Enum.find(state.active_work, fn {_work_id, active} -> active.task.ref == ref end)
  end

  defp timeout_ref(_work_id, :infinity), do: nil

  defp timeout_ref(work_id, timeout) when is_integer(timeout) and timeout >= 0 do
    Process.send_after(self(), {:work_timeout, work_id}, timeout)
  end

  defp timeout_ref(work_id, _timeout) do
    Process.send_after(self(), {:work_timeout, work_id}, @default_timeout)
  end

  defp cancel_timeout(nil), do: :ok
  defp cancel_timeout(ref), do: Process.cancel_timer(ref)

  defp restore_context(nil), do: Context.clear()
  defp restore_context(%Context{} = context), do: Context.put(context)

  defp new_work_id do
    "work_" <> Integer.to_string(System.unique_integer([:positive, :monotonic]), 36)
  end
end
