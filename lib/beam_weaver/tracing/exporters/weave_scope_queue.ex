defmodule BeamWeaver.Tracing.Exporters.WeaveScope.Config do
  @moduledoc false

  @default_flush_interval 250

  defstruct api_key: nil,
            endpoint: nil,
            version: nil,
            otp_app: :beam_weaver,
            transport: Req,
            batch_size: 50,
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
      endpoint: Keyword.get(opts, :endpoint),
      version: Keyword.get(opts, :version),
      otp_app: Keyword.get(opts, :otp_app, :beam_weaver),
      transport: Keyword.get(opts, :transport, Req),
      batch_size: Keyword.get(opts, :batch_size, 50),
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
      endpoint: config.endpoint,
      version: config.version,
      otp_app: config.otp_app,
      transport: config.transport
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end
end

defmodule BeamWeaver.Tracing.Exporters.WeaveScope.Queue do
  @moduledoc """
  Supervised async native WeaveScope exporter queue.

  The queue owns batching, retries, overflow behavior, dead letters, redaction,
  and telemetry. Rejections returned by WeaveScope are terminal because they
  represent invalid payload events, not transient transport failures.
  """

  use GenServer

  @behaviour BeamWeaver.Tracing.Exporter

  alias BeamWeaver.Telemetry.WeaveScopeEvent
  alias BeamWeaver.Tracing.Exporters.WeaveScope
  alias BeamWeaver.Tracing.Exporters.WeaveScope.Config
  alias BeamWeaver.Tracing.Run

  defstruct queue: :queue.new(),
            dead_letters: [],
            config: %Config{},
            flushing?: false

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc false
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :id, Keyword.get(opts, :name, __MODULE__)),
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      shutdown: Keyword.get(opts, :shutdown, 120_000),
      type: :worker
    }
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
      :ok -> stop_server(server, Keyword.get(opts, :reason, :normal), timeout)
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    config = Config.new(opts)
    state = %__MODULE__{config: config}

    if is_integer(config.flush_interval) and config.flush_interval > 0 do
      Process.send_after(self(), :flush_interval, config.flush_interval)
    end

    {:ok, state}
  end

  @impl true
  def handle_cast({:enqueue, event, run, opts}, state) do
    item = new_item(event, redact_run(state, run), opts)
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
      emit(:flush_error, state, nil, %{error: :weavescope_flush_incomplete})
      {:reply, {:error, :weavescope_flush_incomplete}, state}
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
    emit(:drop, state, newest, %{reason: :dropped_newest})

    %{
      state
      | queue: queue,
        dead_letters: [Map.put(newest, :reason, :dropped_newest) | state.dead_letters]
    }
  end

  defp apply_overflow(%{config: %{overflow: :error}} = state) do
    {{:value, newest}, queue} = :queue.out_r(state.queue)
    emit(:drop, state, newest, %{reason: :queue_full})

    %{
      state
      | queue: queue,
        dead_letters: [Map.put(newest, :reason, :queue_full) | state.dead_letters]
    }
  end

  defp apply_overflow(state) do
    {{:value, oldest}, queue} = :queue.out(state.queue)
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
        {:ok, state} -> %{state | flushing?: false}
        {:error, _reason} -> retry_items(%{state | flushing?: false}, items)
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
      {:ok, state} -> %{state | flushing?: false}
      {:error, _reason} -> retry_items(%{state | flushing?: false}, items)
    end
  end

  defp export_items(state, []), do: {:ok, state}

  defp export_items(state, items) do
    export_items_coalesced(state, coalesce_items(items))
  end

  defp export_items_coalesced(state, []), do: {:ok, state}

  defp export_items_coalesced(%{config: %{api_key: api_key}} = state, items)
       when api_key in [nil, ""] do
    Enum.each(items, &emit(:no_api_key, state, &1, %{result: :noop}))
    {:ok, state}
  end

  defp export_items_coalesced(%{config: %{endpoint: endpoint}} = state, items)
       when endpoint in [nil, ""] do
    Enum.each(items, &emit(:no_endpoint, state, &1, %{result: :noop}))
    {:ok, state}
  end

  defp export_items_coalesced(state, items) do
    exportable = Enum.map(items, fn item -> {item.event, item.run, item.opts} end)

    case WeaveScope.export_batch(exportable, Config.exporter_opts(state.config)) do
      :ok ->
        Enum.each(items, &emit(:upload_success, state, &1, %{result: :ok}))
        {:ok, state}

      {:rejected, rejected} ->
        {:ok, dead_letter_rejections(state, items, rejected)}

      {:error, reason} = error ->
        Enum.each(items, &emit(:upload_failure, state, &1, %{error: inspect(reason)}))
        error
    end
  end

  defp coalesce_items(items) do
    {order, by_run_id} =
      Enum.reduce(items, {[], %{}}, fn item, {order, by_run_id} ->
        run_id = item.run.id

        order =
          if Map.has_key?(by_run_id, run_id), do: order, else: [run_id | order]

        by_run_id =
          Map.update(by_run_id, run_id, item, fn existing ->
            if lifecycle_rank(item.event) >= lifecycle_rank(existing.event), do: item, else: existing
          end)

        {order, by_run_id}
      end)

    order
    |> Enum.reverse()
    |> Enum.map(&Map.fetch!(by_run_id, &1))
  end

  defp lifecycle_rank(:started), do: 1
  defp lifecycle_rank(:ok), do: 2
  defp lifecycle_rank(:error), do: 3
  defp lifecycle_rank(_event), do: 0

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
        rejection = Map.get(rejected_by_id, item.run.id) || Map.get(rejected_indexes, index) || %{}
        emit(:upload_rejected, state, item, %{reason: Map.get(rejection, "code"), error: Map.get(rejection, "reason")})
        Map.merge(item, %{reason: :rejected, rejection: rejection})
      end)

    %{state | dead_letters: dead_letters ++ state.dead_letters}
  end

  defp retry_items(state, items) do
    now = System.monotonic_time(:millisecond)

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
    BeamWeaver.Telemetry.emit(
      [:beam_weaver, :weave_scope, :queue, operation],
      %{count: Map.get(metadata, :count, 1)},
      %WeaveScopeEvent{
        operation: operation,
        queue: self(),
        run_id: item_run_id(item),
        trace_id: item_trace_id(item),
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

  defp item_run_id(%{run: %Run{id: id}}), do: id
  defp item_run_id(_item), do: nil

  defp item_trace_id(%{run: %Run{trace_id: trace_id}}), do: trace_id
  defp item_trace_id(_item), do: nil

  defp flush_for_stop(server, timeout) do
    GenServer.call(server, :flush, timeout)
  catch
    :exit, {:timeout, _} -> {:error, :weavescope_flush_incomplete}
    :exit, _reason -> {:error, :weavescope_flush_incomplete}
  end

  defp stop_server(server, reason, timeout) do
    GenServer.stop(server, reason, timeout)
  catch
    :exit, {:timeout, _} -> {:error, :weavescope_flush_incomplete}
    :exit, _reason -> {:error, :weavescope_flush_incomplete}
  end
end
