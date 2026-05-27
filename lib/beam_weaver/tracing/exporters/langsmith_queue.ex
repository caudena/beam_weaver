defmodule BeamWeaver.Tracing.Exporters.LangSmith.Config do
  @moduledoc false

  @default_flush_interval 250

  defstruct api_key: nil,
            project: nil,
            endpoint: nil,
            transport: Req,
            batch_size: 10,
            flush_interval: @default_flush_interval,
            max_items: 10_000,
            overflow: :drop_oldest,
            retry_delay: 100,
            backoff: 2.0,
            jitter: 0.0,
            max_attempts: 5,
            redactor: &BeamWeaver.Tracing.Redactor.redact/1

  def new(opts \\ []) do
    %__MODULE__{
      api_key: Keyword.get(opts, :api_key),
      project: Keyword.get(opts, :project),
      endpoint: Keyword.get(opts, :endpoint),
      transport: Keyword.get(opts, :transport, Req),
      batch_size: Keyword.get(opts, :batch_size, 10),
      flush_interval: Keyword.get(opts, :flush_interval, @default_flush_interval),
      max_items: Keyword.get(opts, :max_items, 10_000),
      overflow: Keyword.get(opts, :overflow, :drop_oldest),
      retry_delay: Keyword.get(opts, :retry_delay, 100),
      backoff: Keyword.get(opts, :backoff, 2.0),
      jitter: Keyword.get(opts, :jitter, 0.0),
      max_attempts: Keyword.get(opts, :max_attempts, 5),
      redactor: Keyword.get(opts, :redactor, &BeamWeaver.Tracing.Redactor.redact/1)
    }
  end

  def exporter_opts(%__MODULE__{} = config) do
    [
      api_key: config.api_key,
      project: config.project,
      endpoint: config.endpoint,
      transport: config.transport
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end
end

defmodule BeamWeaver.Tracing.Exporters.LangSmith.QueueStore do
  @moduledoc false

  @callback put(term(), map()) :: :ok | {:error, term()}
  @callback delete(term(), String.t()) :: :ok | {:error, term()}
  @callback list(term(), keyword()) :: [map()] | {:error, term()}
end

defmodule BeamWeaver.Tracing.Exporters.LangSmith.QueueStore.ETS do
  @moduledoc false
  @behaviour BeamWeaver.Tracing.Exporters.LangSmith.QueueStore

  defstruct [:table]

  def new(opts \\ []) do
    %__MODULE__{
      table: :ets.new(Keyword.get(opts, :table, :beam_weaver_langsmith_queue), [:set, :public])
    }
  end

  @impl true
  def put(%__MODULE__{} = store, item) do
    :ets.insert(store.table, {item.id, item})
    :ok
  end

  @impl true
  def delete(%__MODULE__{} = store, id) do
    :ets.delete(store.table, id)
    :ok
  end

  @impl true
  def list(%__MODULE__{} = store, _opts) do
    store.table
    |> :ets.tab2list()
    |> Enum.map(&elem(&1, 1))
    |> Enum.sort_by(& &1.enqueued_at)
  end
end

defmodule BeamWeaver.Tracing.Exporters.LangSmith.Queue do
  @moduledoc """
  Supervised async LangSmith exporter queue.

  Runtime code emits tracing/telemetry; this process owns retention, retrying,
  redaction, batching, and upload at the boundary.
  """

  use GenServer

  @behaviour BeamWeaver.Tracing.Exporter

  alias BeamWeaver.Telemetry.LangSmithEvent
  alias BeamWeaver.Tracing.Exporters.LangSmith
  alias BeamWeaver.Tracing.Exporters.LangSmith.Config
  alias BeamWeaver.Tracing.Run

  defstruct queue: :queue.new(),
            dead_letters: [],
            config: %Config{},
            flushing?: false,
            store: nil

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl BeamWeaver.Tracing.Exporter
  def export(event, %Run{} = run, opts) do
    queue = Keyword.get(opts, :queue, __MODULE__)
    enqueue(queue, event, run, Keyword.get(opts, :queue_opts, []))
  end

  @spec enqueue(GenServer.server(), atom(), Run.t(), keyword()) :: :ok
  def enqueue(server \\ __MODULE__, event, %Run{} = run, opts \\ []) do
    GenServer.cast(server, {:enqueue, event, run, opts})
  end

  @spec dead_letters(GenServer.server()) :: [map()]
  def dead_letters(server \\ __MODULE__), do: GenServer.call(server, :dead_letters)

  @spec flush(GenServer.server(), timeout()) :: :ok | {:error, term()}
  def flush(server \\ __MODULE__, timeout \\ 5_000), do: GenServer.call(server, :flush, timeout)

  @spec stop(GenServer.server(), keyword()) :: :ok | {:error, term()}
  def stop(server \\ __MODULE__, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 5_000)

    case flush_for_stop(server, timeout) do
      :ok ->
        stop_server(server, Keyword.get(opts, :reason, :normal), timeout)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    config = Config.new(opts)
    store = Keyword.get(opts, :store)

    state = %__MODULE__{config: config, store: store}

    if is_integer(config.flush_interval) and config.flush_interval > 0 do
      Process.send_after(self(), :flush_interval, config.flush_interval)
    end

    {:ok, restore_store(state)}
  end

  @impl true
  def handle_cast({:enqueue, event, run, opts}, state) do
    item = new_item(event, redact_run(state, run), opts)
    persist_item(state, item)
    state = enqueue_item(state, item)
    emit(:enqueue, state, item, %{result: :ok})

    if is_integer(state.config.flush_interval) and state.config.flush_interval > 0 do
      {:noreply, state}
    else
      {:noreply, drain_due(state)}
    end
  end

  @impl true
  def handle_call(:flush, _from, state) do
    emit(:flush_start, state, nil, %{count: :queue.len(state.queue)})
    state = drain_all(state)

    if :queue.is_empty(state.queue) do
      emit(:flush_stop, state, nil, %{result: :ok})
      {:reply, :ok, state}
    else
      emit(:flush_error, state, nil, %{error: :langsmith_flush_incomplete})
      {:reply, {:error, :langsmith_flush_incomplete}, state}
    end
  end

  def handle_call(:dead_letters, _from, state),
    do: {:reply, Enum.reverse(state.dead_letters), state}

  @impl true
  def handle_info(:retry, state), do: {:noreply, drain_due(state)}

  def handle_info(:flush_interval, state) do
    if is_integer(state.config.flush_interval) and state.config.flush_interval > 0 do
      Process.send_after(self(), :flush_interval, state.config.flush_interval)
    end

    {:noreply, drain_due(state)}
  end

  @impl true
  def terminate(_reason, state) do
    drain_all(state)
    :ok
  end

  defp enqueue_item(%__MODULE__{config: config} = state, item) do
    queue = :queue.in(item, state.queue)

    if :queue.len(queue) <= config.max_items do
      %{state | queue: queue}
    else
      apply_overflow(%{state | queue: queue})
    end
  end

  defp apply_overflow(%{config: %{overflow: :drop_newest}} = state) do
    {{:value, newest}, queue} = :queue.out_r(state.queue)
    delete_item(state, newest)
    emit(:drop, state, newest, %{reason: :dropped_newest})

    %{
      state
      | queue: queue,
        dead_letters: [Map.put(newest, :reason, :dropped_newest) | state.dead_letters]
    }
  end

  defp apply_overflow(%{config: %{overflow: :error}} = state) do
    {{:value, newest}, queue} = :queue.out_r(state.queue)
    delete_item(state, newest)
    emit(:drop, state, newest, %{reason: :queue_full})

    %{
      state
      | queue: queue,
        dead_letters: [Map.put(newest, :reason, :queue_full) | state.dead_letters]
    }
  end

  defp apply_overflow(state) do
    {{:value, oldest}, queue} = :queue.out(state.queue)
    delete_item(state, oldest)
    emit(:drop, state, oldest, %{reason: :dropped_oldest})

    %{
      state
      | queue: queue,
        dead_letters: [Map.put(oldest, :reason, :dropped_oldest) | state.dead_letters]
    }
  end

  defp drain_due(%{flushing?: true} = state), do: state

  defp drain_due(%__MODULE__{} = state) do
    now = System.monotonic_time(:millisecond)
    {items, queue} = take_due(state.queue, state.config.batch_size, now)
    state = %{state | queue: queue, flushing?: true}

    state =
      case export_items(state, items) do
        :ok ->
          Enum.each(items, &delete_item(state, &1))
          %{state | flushing?: false}

        {:error, _reason} ->
          retry_items(%{state | flushing?: false}, items)
      end

    if not :queue.is_empty(state.queue),
      do: Process.send_after(self(), :retry, state.config.retry_delay)

    state
  end

  defp drain_all(state) do
    if :queue.is_empty(state.queue) do
      %{state | flushing?: false}
    else
      state |> drain_any() |> drain_all()
    end
  end

  defp drain_any(%__MODULE__{} = state) do
    {items, queue} = take_any(state.queue, state.config.batch_size)
    state = %{state | queue: queue, flushing?: true}

    case export_items(state, items) do
      :ok ->
        Enum.each(items, &delete_item(state, &1))
        %{state | flushing?: false}

      {:error, _reason} ->
        retry_items(%{state | flushing?: false}, items)
    end
  end

  defp export_items(_state, []), do: :ok

  defp export_items(%{config: %{api_key: api_key}} = state, items)
       when api_key in [nil, ""] do
    Enum.each(items, &emit(:no_api_key, state, &1, %{result: :noop}))
    :ok
  end

  defp export_items(state, items) do
    exportable = Enum.map(items, fn item -> {item.event, item.run, item.opts} end)

    case LangSmith.export_batch(exportable, Config.exporter_opts(state.config)) do
      :ok ->
        Enum.each(items, &emit(:upload_success, state, &1, %{result: :ok}))
        :ok

      {:error, reason} = error ->
        Enum.each(items, &emit(:upload_failure, state, &1, %{error: inspect(reason)}))
        error
    end
  end

  defp retry_items(state, items) do
    now = System.monotonic_time(:millisecond)

    Enum.reduce(items, state, fn item, acc ->
      attempts = item.attempts + 1

      if attempts >= acc.config.max_attempts do
        delete_item(acc, item)
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

  defp take_due(queue, limit, now), do: take_due(queue, limit, now, [])
  defp take_due(queue, 0, _now, items), do: {Enum.reverse(items), queue}

  defp take_due(queue, count, now, items) do
    case :queue.out(queue) do
      {{:value, %{retry_at: retry_at} = item}, queue} when retry_at <= now ->
        take_due(queue, count - 1, now, [item | items])

      {{:value, item}, queue} ->
        {Enum.reverse(items), :queue.in_r(item, queue)}

      {:empty, queue} ->
        {Enum.reverse(items), queue}
    end
  end

  defp take_any(queue, limit), do: take_any(queue, limit, [])
  defp take_any(queue, 0, items), do: {Enum.reverse(items), queue}

  defp take_any(queue, count, items) do
    case :queue.out(queue) do
      {{:value, item}, queue} -> take_any(queue, count - 1, [item | items])
      {:empty, queue} -> {Enum.reverse(items), queue}
    end
  end

  defp new_item(event, run, opts) do
    %{
      id: "lsq_" <> Integer.to_string(System.unique_integer([:positive, :monotonic]), 36),
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
        error: redactor.(run.error)
    }
  end

  defp persist_item(%{store: nil}, _item), do: :ok
  defp persist_item(%{store: %{__struct__: module} = store}, item), do: module.put(store, item)

  defp delete_item(%{store: nil}, _item), do: :ok

  defp delete_item(%{store: %{__struct__: module} = store}, item),
    do: module.delete(store, item.id)

  defp restore_store(%{store: nil} = state), do: state

  defp restore_store(%{store: %{__struct__: module} = store} = state) do
    case module.list(store, []) do
      items when is_list(items) ->
        Enum.reduce(items, state, &enqueue_item(&2, &1))

      _error ->
        state
    end
  end

  defp emit(operation, state, item, metadata) do
    BeamWeaver.Telemetry.emit(
      [:beam_weaver, :langsmith, :queue, operation],
      %{count: Map.get(metadata, :count, 1)},
      %LangSmithEvent{
        operation: operation,
        queue: self(),
        run_id: item_run_id(item),
        trace_id: item_trace_id(item),
        attempts: Map.get(metadata, :attempts),
        reason: Map.get(metadata, :reason),
        result: Map.get(metadata, :result),
        error: Map.get(metadata, :error),
        metadata: %{
          project: state.config.project,
          retry_at: Map.get(metadata, :retry_at)
        }
      }
    )
  end

  defp item_run_id(%{run: %Run{id: id}}), do: id
  defp item_run_id(_item), do: nil

  defp item_trace_id(%{run: %Run{trace_id: trace_id}}), do: trace_id
  defp item_trace_id(_item), do: nil

  defp flush_for_stop(server, timeout) do
    GenServer.call(server, :flush, timeout)
  catch
    :exit, {:timeout, _} -> {:error, :langsmith_flush_incomplete}
    :exit, _reason -> {:error, :langsmith_flush_incomplete}
  end

  defp stop_server(server, reason, timeout) do
    GenServer.stop(server, reason, timeout)
  catch
    :exit, {:timeout, _} -> {:error, :langsmith_flush_incomplete}
    :exit, _reason -> {:error, :langsmith_flush_incomplete}
  end
end
