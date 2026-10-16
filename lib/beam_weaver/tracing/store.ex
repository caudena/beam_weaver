defmodule BeamWeaver.Tracing.Store do
  @moduledoc false

  # Keeps the runs of this node in memory. Running runs always stay; once more
  # than `config :beam_weaver, :tracing, max_runs:` runs are stored, the runs
  # that finished first are removed. The store watches the process that starts
  # each run: when it exits with the run still running, as a node or tool task
  # killed at its timeout does, the run fails with the exit reason, so it is
  # removed like the others, and the exporter the run started with gets its
  # `:error` event.

  use GenServer

  alias BeamWeaver.Tracing
  alias BeamWeaver.Tracing.Run

  @default_max_runs 10_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))
  end

  # `exporter` is the `{module, opts}` the run's events go to, or `nil`; it
  # gets the run's `:error` event if the run's process exits first.
  @spec put(Run.t(), {module(), keyword()} | nil) :: :ok
  def put(%Run{} = run, exporter), do: GenServer.call(__MODULE__, {:put, run, exporter, self()})

  @spec get(Run.id()) :: {:ok, Run.t()} | :error
  def get(run_id), do: GenServer.call(__MODULE__, {:get, run_id})

  @spec update(Run.id(), (Run.t() -> Run.t())) :: {:ok, Run.t()} | :error
  def update(run_id, updater) when is_function(updater, 1),
    do: GenServer.call(__MODULE__, {:update, run_id, updater})

  @spec list() :: [Run.t()]
  def list, do: GenServer.call(__MODULE__, :list)

  @spec tree(Run.id()) :: {:ok, map()} | :error
  def tree(run_id), do: GenServer.call(__MODULE__, {:tree, run_id})

  @spec clear() :: :ok
  def clear, do: GenServer.call(__MODULE__, :clear)

  @impl true
  def init(:ok), do: {:ok, new_state()}

  @impl true
  def handle_call({:put, run, exporter, owner}, _from, state) do
    {:reply, :ok, state |> put_run(nil, run) |> watch(run, owner, exporter) |> trim(max_runs())}
  end

  def handle_call({:get, run_id}, _from, state), do: {:reply, Map.fetch(state.runs, run_id), state}

  def handle_call({:update, run_id, updater}, _from, state) do
    case Map.fetch(state.runs, run_id) do
      {:ok, %Run{} = run} ->
        updated = updater.(run)
        {:reply, {:ok, updated}, state |> put_run(run, updated) |> trim(max_runs())}

      :error ->
        {:reply, :error, state}
    end
  end

  def handle_call(:list, _from, state) do
    {:reply, state.runs |> Map.values() |> Enum.sort_by(&timestamp_key/1), state}
  end

  def handle_call({:tree, run_id}, _from, state) do
    reply =
      with {:ok, run} <- Map.fetch(state.runs, run_id) do
        children = state.runs |> Map.values() |> Enum.group_by(& &1.parent_id)
        {:ok, build_tree(run, children)}
      end

    {:reply, reply, state}
  end

  def handle_call(:clear, _from, state) do
    Enum.each(state.owners, fn {_owner, {ref, _run_ids}} -> Process.demonitor(ref, [:flush]) end)
    {:reply, :ok, new_state()}
  end

  # The process that started these runs exited before finishing them.
  @impl true
  def handle_info({:DOWN, _ref, :process, owner, reason}, state) do
    {{_ref, run_ids}, owners} = Map.pop(state.owners, owner, {nil, MapSet.new()})
    run_ids = MapSet.to_list(run_ids)
    error = BeamWeaver.Tracing.Redactor.redact(%{kind: :exit, reason: inspect(reason)})
    {exporters, kept_exporters} = Map.split(state.exporters, run_ids)

    state = %{
      state
      | owners: owners,
        owned: Map.drop(state.owned, run_ids),
        exporters: kept_exporters
    }

    {failed, state} =
      run_ids
      |> Enum.flat_map(&running(state, &1))
      |> Enum.sort_by(&timestamp_key/1)
      |> Enum.map_reduce(state, fn run, state ->
        failed = %{run | status: :error, ended_at: DateTime.utc_now(), error: error}
        {failed, put_run(state, run, failed)}
      end)

    export_failed(failed, exporters)
    {:noreply, trim(state, max_runs())}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # Keep the exporters' options, which may hold an API key, out of the state a
  # crash or `:sys.get_status/1` would print.
  @impl true
  def format_status(%{state: %{exporters: _exporters} = state} = status),
    do: %{status | state: %{state | exporters: :redacted}}

  def format_status(status), do: status

  # `owners` maps each watched process to its monitor and the ids of its
  # running runs; `owned` maps those ids back to the process, and `exporters`
  # to the exporter each run started with.
  defp new_state, do: %{runs: %{}, finished: :queue.new(), owners: %{}, owned: %{}, exporters: %{}}

  # The exporters get the `:error` events from a separate process, in the
  # order the runs started: an exporter may make its caller wait, as the
  # WeaveScope queue does while it is full, and every run's calls go through
  # the store.
  defp export_failed(failed, exporters) do
    events = for %Run{id: run_id} = run <- failed, exporter = Map.get(exporters, run_id), do: {run, exporter}

    if events != [] do
      Task.start(fn -> Enum.each(events, fn {run, exporter} -> Tracing.export_event(:error, run, exporter) end) end)
    end

    :ok
  end

  # Stores `run`, which replaces `previous`.
  defp put_run(state, previous, %Run{} = run) do
    state
    |> Map.update!(:runs, &Map.put(&1, run.id, run))
    |> track_finished(previous, run)
  end

  defp running(state, run_id) do
    case Map.fetch(state.runs, run_id) do
      {:ok, %Run{status: :running} = run} -> [run]
      _other -> []
    end
  end

  defp watch(state, %Run{status: :running, id: run_id}, owner, exporter) do
    state = unwatch(state, run_id)

    {ref, run_ids} =
      case Map.fetch(state.owners, owner) do
        {:ok, {ref, run_ids}} -> {ref, run_ids}
        :error -> {Process.monitor(owner), MapSet.new()}
      end

    %{
      state
      | owners: Map.put(state.owners, owner, {ref, MapSet.put(run_ids, run_id)}),
        owned: Map.put(state.owned, run_id, owner),
        exporters: if(exporter, do: Map.put(state.exporters, run_id, exporter), else: state.exporters)
    }
  end

  defp watch(state, _run, _owner, _exporter), do: state

  # Stops watching the process of a run that finished; a process with no
  # running run left isn't watched.
  defp unwatch(state, run_id) do
    state = %{state | exporters: Map.delete(state.exporters, run_id)}

    with {owner, owned} when is_pid(owner) <- Map.pop(state.owned, run_id),
         {:ok, {ref, run_ids}} <- Map.fetch(state.owners, owner) do
      run_ids = MapSet.delete(run_ids, run_id)

      owners =
        if MapSet.size(run_ids) == 0 do
          Process.demonitor(ref, [:flush])
          Map.delete(state.owners, owner)
        else
          Map.put(state.owners, owner, {ref, run_ids})
        end

      %{state | owners: owners, owned: owned}
    else
      _other -> state
    end
  end

  # Remembers the order in which runs finish, so the oldest go first.
  defp track_finished(state, previous, %Run{status: status} = run) when status != :running do
    if is_nil(previous) or previous.status == :running,
      do: unwatch(%{state | finished: :queue.in(run.id, state.finished)}, run.id),
      else: state
  end

  defp track_finished(state, _previous, _run), do: state

  defp trim(state, max_runs) when map_size(state.runs) > max_runs do
    case :queue.out(state.finished) do
      {{:value, run_id}, finished} ->
        trim(%{state | runs: Map.delete(state.runs, run_id), finished: finished}, max_runs)

      {:empty, _finished} ->
        state
    end
  end

  defp trim(state, _max_runs), do: state

  defp max_runs do
    case BeamWeaver.Config.get([:tracing, :max_runs], @default_max_runs) do
      max_runs when is_integer(max_runs) and max_runs >= 0 -> max_runs
      _invalid -> @default_max_runs
    end
  end

  defp build_tree(%Run{} = run, children) do
    %{
      run: run,
      children:
        children
        |> Map.get(run.id, [])
        |> Enum.sort_by(&timestamp_key/1)
        |> Enum.map(&build_tree(&1, children))
    }
  end

  defp timestamp_key(run) do
    DateTime.to_unix(run.started_at, :microsecond)
  end
end
