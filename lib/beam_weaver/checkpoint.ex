defmodule BeamWeaver.Checkpoint do
  @moduledoc """
  Public helpers for graph checkpoint savers.

  Checkpoint savers are adapter structs that implement
  `BeamWeaver.Checkpoint.Saver`. The graph runtime depends on this contract, not
  on ETS, Ecto, or any other backend-specific module.
  """

  alias BeamWeaver.Checkpoint.Normalization
  alias BeamWeaver.Checkpoint.Record
  alias BeamWeaver.Checkpoint.Saver
  alias BeamWeaver.Checkpoint.Telemetry
  alias BeamWeaver.Core.Async

  @type saver :: struct()
  @type config :: map()
  @type checkpoint :: map()
  @type metadata :: map()
  @type versions :: map()
  @type writes :: [{String.t(), term()} | {String.t(), String.t(), term()}]

  @spec get(saver(), config()) :: checkpoint() | nil
  def get(saver, config) do
    case get_tuple(saver, config) do
      nil -> nil
      %{checkpoint: checkpoint} -> checkpoint
    end
  end

  @spec async_get(saver(), config(), keyword()) :: Async.handle()
  def async_get(saver, config, opts \\ []) do
    Async.run(fn -> get(saver, config) end, opts)
  end

  @spec get_tuple(saver(), config()) :: map() | nil
  def get_tuple(saver, config) do
    result =
      saver.__struct__.get_tuple(saver, config)
      |> Normalization.normalize_tuple(saver)

    Telemetry.emit(saver, :get_tuple, %{count: if(result, do: 1, else: 0)}, config, result)
    result
  end

  @spec async_get_tuple(saver(), config(), keyword()) :: Async.handle()
  def async_get_tuple(saver, config, opts \\ []) do
    Async.run(fn -> get_tuple(saver, config) end, opts)
  end

  @spec get_record(saver(), config()) :: Record.t() | nil
  def get_record(saver, config) do
    case get_tuple(saver, config) do
      nil -> nil
      tuple -> Record.from_tuple(tuple)
    end
  end

  @spec list_records(saver(), config() | nil, keyword()) :: [Record.t()]
  def list_records(saver, config \\ nil, opts \\ []) do
    saver
    |> list(config, opts)
    |> Enum.map(&Record.from_tuple/1)
  end

  @spec list(saver(), config() | nil, keyword()) :: [map()]
  def list(saver, config \\ nil, opts \\ []) do
    result =
      saver.__struct__.list(saver, config, opts)
      |> Enum.map(&Normalization.normalize_tuple(&1, saver))

    Telemetry.emit(saver, :list, %{count: length(result)}, config || %{}, result)
    result
  end

  @spec async_list(saver(), config() | nil, keyword()) :: Async.handle()
  def async_list(saver, config \\ nil, opts \\ []) do
    {async_opts, call_opts} = Async.split_opts(opts)
    Async.run(fn -> list(saver, config, call_opts) end, async_opts)
  end

  @spec put(saver(), config(), checkpoint(), metadata(), versions()) ::
          {:ok, config()} | {:error, term()}
  def put(saver, config, checkpoint, metadata, new_versions) do
    result =
      saver.__struct__.put(
        saver,
        config,
        checkpoint,
        Normalization.normalize_metadata(config, metadata),
        new_versions
      )

    Telemetry.emit(saver, :put, %{count: 1}, config, result)
    result
  end

  @spec async_put(saver(), config(), checkpoint(), metadata(), versions(), keyword()) ::
          Async.handle()
  def async_put(saver, config, checkpoint, metadata, new_versions, opts \\ []) do
    Async.run(fn -> put(saver, config, checkpoint, metadata, new_versions) end, opts)
  end

  @spec put_writes(saver(), config(), writes(), String.t(), String.t()) ::
          :ok | {:error, term()}
  def put_writes(saver, config, writes, task_id, task_path \\ "") do
    result = saver.__struct__.put_writes(saver, config, writes, task_id, task_path)

    Telemetry.emit(saver, :put_writes, %{count: length(writes)}, config, result, %{
      task_id: task_id,
      task_path: task_path
    })

    result
  end

  @spec async_put_writes(saver(), config(), writes(), String.t(), String.t(), keyword()) ::
          Async.handle()
  def async_put_writes(saver, config, writes, task_id, task_path \\ "", opts \\ []) do
    Async.run(fn -> put_writes(saver, config, writes, task_id, task_path) end, opts)
  end

  @spec put_checkpoint_with_writes(
          saver(),
          config(),
          checkpoint(),
          metadata(),
          versions(),
          writes(),
          keyword()
        ) :: {:ok, config()} | {:error, term()}
  def put_checkpoint_with_writes(
        saver,
        config,
        checkpoint,
        metadata,
        versions,
        writes,
        opts \\ []
      ) do
    module = saver.__struct__

    if function_exported?(module, :put_checkpoint_with_writes, 7) do
      result =
        module.put_checkpoint_with_writes(
          saver,
          config,
          checkpoint,
          Normalization.normalize_metadata(config, metadata),
          versions,
          writes,
          opts
        )

      Telemetry.emit(saver, :put_checkpoint_with_writes, %{count: length(writes)}, config, result)
      result
    else
      result =
        with {:ok, next_config} <- put(saver, config, checkpoint, metadata, versions),
             :ok <-
               put_writes(
                 saver,
                 next_config,
                 writes,
                 Keyword.get(opts, :task_id, "checkpoint"),
                 Keyword.get(opts, :task_path, "")
               ) do
          {:ok, next_config}
        end

      Telemetry.emit(saver, :put_checkpoint_with_writes, %{count: length(writes)}, config, result)
      result
    end
  end

  @spec async_put_checkpoint_with_writes(
          saver(),
          config(),
          checkpoint(),
          metadata(),
          versions(),
          writes(),
          keyword()
        ) :: Async.handle()
  def async_put_checkpoint_with_writes(
        saver,
        config,
        checkpoint,
        metadata,
        versions,
        writes,
        opts \\ []
      ) do
    {async_opts, call_opts} = Async.split_opts(opts)

    Async.run(
      fn ->
        put_checkpoint_with_writes(
          saver,
          config,
          checkpoint,
          metadata,
          versions,
          writes,
          call_opts
        )
      end,
      async_opts
    )
  end

  @spec get_delta_channel_history(saver(), config(), [term()], keyword()) :: map()
  def get_delta_channel_history(saver, config, channel_names, opts \\ []) do
    saver.__struct__.get_delta_channel_history(
      saver,
      config,
      Enum.map(channel_names, &to_string/1),
      opts
    )
  end

  @spec async_get_delta_channel_history(saver(), config(), [term()], keyword()) :: Async.handle()
  def async_get_delta_channel_history(saver, config, channel_names, opts \\ []) do
    {async_opts, call_opts} = Async.split_opts(opts)

    Async.run(
      fn -> get_delta_channel_history(saver, config, channel_names, call_opts) end,
      async_opts
    )
  end

  @spec delete_thread(saver(), String.t()) :: :ok | {:error, term()}
  def delete_thread(saver, thread_id) do
    result = saver.__struct__.delete_thread(saver, thread_id)

    Telemetry.emit(
      saver,
      :delete_thread,
      %{count: 1},
      %{"configurable" => %{"thread_id" => thread_id}},
      result
    )

    result
  end

  @spec async_delete_thread(saver(), String.t(), keyword()) :: Async.handle()
  def async_delete_thread(saver, thread_id, opts \\ []) do
    Async.run(fn -> delete_thread(saver, thread_id) end, opts)
  end

  @spec delete_for_runs(saver(), [String.t()]) :: :ok | {:error, term()}
  def delete_for_runs(saver, run_ids) when is_list(run_ids) do
    result = saver.__struct__.delete_for_runs(saver, run_ids)

    Telemetry.emit(saver, :delete_for_runs, %{count: length(run_ids)}, %{}, result, %{
      run_ids: run_ids
    })

    result
  end

  @spec async_delete_for_runs(saver(), [String.t()], keyword()) :: Async.handle()
  def async_delete_for_runs(saver, run_ids, opts \\ []) do
    Async.run(fn -> delete_for_runs(saver, run_ids) end, opts)
  end

  @spec copy_thread(saver(), String.t(), String.t()) :: :ok | {:error, term()}
  def copy_thread(saver, source_thread_id, target_thread_id) do
    result = saver.__struct__.copy_thread(saver, source_thread_id, target_thread_id)

    Telemetry.emit(saver, :copy_thread, %{count: 1}, %{}, result, %{
      source_thread_id: source_thread_id,
      target_thread_id: target_thread_id
    })

    result
  end

  @spec async_copy_thread(saver(), String.t(), String.t(), keyword()) :: Async.handle()
  def async_copy_thread(saver, source_thread_id, target_thread_id, opts \\ []) do
    Async.run(fn -> copy_thread(saver, source_thread_id, target_thread_id) end, opts)
  end

  @spec prune(saver(), [String.t()], keyword()) :: :ok | {:error, term()}
  def prune(saver, thread_ids, opts \\ []) do
    result = saver.__struct__.prune(saver, thread_ids, opts)

    Telemetry.emit(saver, :prune, %{count: length(thread_ids)}, %{}, result, %{
      thread_ids: thread_ids
    })

    result
  end

  @spec async_prune(saver(), [String.t()], keyword()) :: Async.handle()
  def async_prune(saver, thread_ids, opts \\ []) do
    {async_opts, call_opts} = Async.split_opts(opts)
    Async.run(fn -> prune(saver, thread_ids, call_opts) end, async_opts)
  end

  @spec next_version(saver(), term(), term() | nil) :: term()
  def next_version(saver, current, channel), do: Saver.next_version(saver, current, channel)

  @doc """
  Normalizes a graph run config into LangGraph-compatible configurable keys.
  """
  @spec configurable(config() | keyword()) :: map()
  defdelegate configurable(config), to: Normalization
end
