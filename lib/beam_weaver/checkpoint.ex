defmodule BeamWeaver.Checkpoint do
  @moduledoc ~S"""
  Read, write, fork and retain graph checkpoint history through explicit savers.

  A saver is a struct implementing `BeamWeaver.Checkpoint.Saver`. Use these
  facade functions for normalized results and telemetry. Prefer `fetch_tuple/2`
  and `list_result/3` when storage failure must be handled as a value; legacy
  convenience reads can raise rather than disguising failures as absence.

  A config identifies thread, namespace and optionally an exact checkpoint.
  Writes create history; they do not make external actions transactional.
  Retention must preserve delta dependencies needed to reconstruct later state.
  See [Checkpoints](checkpoints.md) and [Storage](storage.md).
  """

  alias BeamWeaver.Checkpoint.Normalization
  alias BeamWeaver.Checkpoint.Batch
  alias BeamWeaver.Checkpoint.Record
  alias BeamWeaver.Checkpoint.Saver
  alias BeamWeaver.Checkpoint.Telemetry
  alias BeamWeaver.Core.Error

  @type saver :: struct()
  @type config :: map()
  @type checkpoint :: map()
  @type metadata :: map()
  @type versions :: map()
  @type writes :: [{String.t(), term()} | {String.t(), String.t(), term()}]

  @doc """
  Returns the stored checkpoint payload or nil. Storage errors raise; use fetch_tuple/2 for tagged errors.
  """
  @spec get(saver(), config()) :: checkpoint() | nil
  def get(saver, config) do
    case get_tuple(saver, config) do
      nil -> nil
      %{checkpoint: checkpoint} -> checkpoint
    end
  end

  @doc """
  Returns the normalized checkpoint tuple map or nil. Storage errors raise rather than returning absence.
  """
  @spec get_tuple(saver(), config()) :: map() | nil
  def get_tuple(saver, config) do
    case fetch_tuple(saver, config) do
      {:ok, result} -> result
      {:error, error} -> raise_checkpoint_error!(error)
    end
  end

  @doc """
  Reads one checkpoint without collapsing adapter failures into absence.

  Saver implementations may provide a native `fetch_tuple/2` callback. Older
  savers remain compatible: their `get_tuple/2` callback is wrapped and raised
  exceptions are returned as checkpoint errors.
  """
  @spec fetch_tuple(saver(), config()) :: {:ok, map() | nil} | {:error, term()}
  def fetch_tuple(saver, config) do
    result =
      checkpoint_read(saver, :fetch_tuple, [config], fn ->
        saver.__struct__.get_tuple(saver, config)
      end)

    normalized =
      case result do
        {:ok, tuple} when is_map(tuple) or is_nil(tuple) ->
          checkpoint_read(fn -> Normalization.normalize_tuple(tuple, saver) end)

        {:ok, other} ->
          invalid_read_result(:fetch_tuple, other)

        {:error, _error} = error ->
          error
      end

    Telemetry.emit(
      saver,
      :fetch_tuple,
      %{count: if(match?({:ok, %{}}, normalized), do: 1, else: 0)},
      config,
      normalized
    )

    normalized
  end

  @doc """
  Returns the tuple projected as Checkpoint.Record, or nil; storage errors follow get_tuple/2.
  """
  @spec get_record(saver(), config()) :: Record.t() | nil
  def get_record(saver, config) do
    case get_tuple(saver, config) do
      nil -> nil
      tuple -> Record.from_tuple(tuple)
    end
  end

  @doc """
  Returns newest-first typed records using the same filters as list/3.
  """
  @spec list_records(saver(), config() | nil, keyword()) :: [Record.t()]
  def list_records(saver, config \\ nil, opts \\ []) do
    saver
    |> list(config, opts)
    |> Enum.map(&Record.from_tuple/1)
  end

  @doc """
  Returns newest-first checkpoint tuples. Supports limit, before and metadata filters; storage errors raise.
  """
  @spec list(saver(), config() | nil, keyword()) :: [map()]
  def list(saver, config \\ nil, opts \\ []) do
    case list_result(saver, config, opts) do
      {:ok, result} -> result
      {:error, error} -> raise_checkpoint_error!(error)
    end
  end

  @doc """
  Lists checkpoints without turning an adapter failure into an empty history.
  """
  @spec list_result(saver(), config() | nil, keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def list_result(saver, config \\ nil, opts \\ []) do
    result =
      checkpoint_read(saver, :list_result, [config, opts], fn ->
        saver.__struct__.list(saver, config, opts)
      end)

    normalized =
      case result do
        {:ok, tuples} when is_list(tuples) ->
          checkpoint_read(fn -> Enum.map(tuples, &Normalization.normalize_tuple(&1, saver)) end)

        {:ok, other} ->
          invalid_read_result(:list_result, other)

        {:error, _error} = error ->
          error
      end

    count = if match?({:ok, _}, normalized), do: length(elem(normalized, 1)), else: 0
    Telemetry.emit(saver, :list_result, %{count: count}, config || %{}, normalized)
    normalized
  end

  @doc """
  Stores one checkpoint with metadata/channel versions and returns its identifying config.
  """
  @spec put(saver(), config(), checkpoint(), metadata(), versions()) ::
          {:ok, config()} | {:error, term()}
  def put(saver, config, checkpoint, metadata, new_versions) do
    args = [config, checkpoint, Normalization.normalize_metadata(config, metadata), new_versions]
    call_saver(saver, :put, args, 1, config)
  end

  @doc """
  Persists a task's pending channel writes under the selected checkpoint and task path.
  """
  @spec put_writes(saver(), config(), writes(), String.t(), String.t()) ::
          :ok | {:error, term()}
  def put_writes(saver, config, writes, task_id, task_path \\ "") do
    metadata = %{task_id: task_id, task_path: task_path}
    call_saver(saver, :put_writes, [config, writes, task_id, task_path], length(writes), config, metadata)
  end

  @doc """
  Atomically persists a checkpoint and pending writes when supported by the saver.
  Returns :atomic_checkpoint_write_unsupported rather than performing a non-atomic fallback.
  """
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

    result =
      if BeamWeaver.Behaviour.exported?(module, :put_checkpoint_with_writes, 7) do
        module.put_checkpoint_with_writes(
          saver,
          config,
          checkpoint,
          Normalization.normalize_metadata(config, metadata),
          versions,
          writes,
          opts
        )
      else
        {:error,
         Error.new(
           :atomic_checkpoint_write_unsupported,
           "checkpoint saver does not support atomic checkpoint and write persistence",
           %{saver: inspect(module)}
         )}
      end

    Telemetry.emit(saver, :put_checkpoint_with_writes, %{count: length(writes)}, config, result)
    result
  end

  @doc """
  Atomically stores a bounded list of checkpoints and their pending writes.

  Atomicity belongs to the saver. No sequential fallback is attempted.
  """
  @spec put_many(saver(), [map()], keyword()) ::
          {:ok, [config()]} | {:error, term()}
  def put_many(saver, entries, opts \\ []) do
    with :ok <- Batch.validate(entries),
         {:ok, module} <- required_callback(saver, :put_many, 3) do
      module.put_many(saver, entries, opts)
    end
  end

  @doc """
  Copies the bounded lineage ending at an exact checkpoint into another thread.
  """
  @spec fork_at(saver(), config(), String.t(), keyword()) ::
          {:ok, config()} | {:error, term()}
  def fork_at(saver, source_config, target_thread_id, opts \\ []) do
    if is_binary(target_thread_id) and target_thread_id != "" do
      with {:ok, module} <- required_callback(saver, :fork_at, 4),
           do: module.fork_at(saver, source_config, target_thread_id, opts)
    else
      {:error, Error.new(:invalid_checkpoint_fork, "target thread id is required")}
    end
  end

  defp call_saver(saver, operation, args, count, config, metadata \\ %{}) do
    result = apply(saver.__struct__, operation, [saver | args])
    Telemetry.emit(saver, operation, %{count: count}, config, result, metadata)
    result
  end

  defp checkpoint_read(saver, callback, args, fallback) do
    module = saver.__struct__

    if BeamWeaver.Behaviour.exported?(module, callback, length(args) + 1) do
      checkpoint_read(fn -> apply(module, callback, [saver | args]) end)
    else
      checkpoint_read(fallback)
    end
  end

  defp required_callback(saver, callback, arity) do
    module = saver.__struct__

    if BeamWeaver.Behaviour.exported?(module, callback, arity) do
      {:ok, module}
    else
      {:error,
       Error.new(:checkpoint_operation_unsupported, "checkpoint saver lacks required callback", %{
         saver: inspect(module),
         callback: callback,
         arity: arity
       })}
    end
  end

  defp checkpoint_read(fun) do
    case fun.() do
      {:ok, _value} = result -> result
      {:error, _error} = error -> error
      value -> {:ok, value}
    end
  rescue
    exception ->
      {:error,
       Error.new(:checkpoint_read_failed, Exception.message(exception), %{
         exception: inspect(exception.__struct__)
       })}
  catch
    kind, reason ->
      {:error,
       Error.new(:checkpoint_read_failed, "checkpoint adapter terminated while reading", %{
         kind: kind,
         reason: inspect(reason)
       })}
  end

  defp invalid_read_result(callback, value) do
    {:error,
     Error.new(:invalid_checkpoint_adapter, "checkpoint read callback returned invalid data", %{
       callback: callback,
       returned: inspect(value)
     })}
  end

  defp raise_checkpoint_error!(%Error{} = error), do: raise(RuntimeError, error.message)
  defp raise_checkpoint_error!(error), do: raise(RuntimeError, inspect(error))

  @doc """
  Reads the earlier writes required to reconstruct the selected delta channels.
  """
  @spec get_delta_channel_history(saver(), config(), [term()], keyword()) :: map()
  def get_delta_channel_history(saver, config, channel_names, opts \\ []) do
    saver.__struct__.get_delta_channel_history(
      saver,
      config,
      Enum.map(channel_names, &to_string/1),
      opts
    )
  end

  @doc """
  Deletes the selected thread history. Authorize this destructive operation in the application.
  """
  @spec delete_thread(saver(), String.t()) :: :ok | {:error, term()}
  def delete_thread(saver, thread_id),
    do: call_saver(saver, :delete_thread, [thread_id], 1, %{"configurable" => %{"thread_id" => thread_id}})

  @doc """
  Deletes selected run history only when the saver can preserve later delta dependencies.
  """
  @spec delete_for_runs(saver(), [String.t()]) :: :ok | {:error, term()}
  def delete_for_runs(saver, run_ids) when is_list(run_ids),
    do: call_saver(saver, :delete_for_runs, [run_ids], length(run_ids), %{}, %{run_ids: run_ids})

  @doc """
  Copies a thread and its stored history to a target thread through the saver.
  """
  @spec copy_thread(saver(), String.t(), String.t()) :: :ok | {:error, term()}
  def copy_thread(saver, source_thread_id, target_thread_id) do
    metadata = %{source_thread_id: source_thread_id, target_thread_id: target_thread_id}
    call_saver(saver, :copy_thread, [source_thread_id, target_thread_id], 1, %{}, metadata)
  end

  @doc """
  Applies saver retention to selected threads, preserving state dependencies for continuation.
  """
  @spec prune(saver(), [String.t()], keyword()) :: :ok | {:error, term()}
  def prune(saver, thread_ids, opts \\ []),
    do: call_saver(saver, :prune, [thread_ids, opts], length(thread_ids), %{}, %{thread_ids: thread_ids})

  @doc """
  Obtains the next channel version through the saver's version policy.
  """
  @spec next_version(saver(), term(), term() | nil) :: term()
  def next_version(saver, current, channel), do: Saver.next_version(saver, current, channel)

  @doc """
  Normalizes a graph run config into a map of string configurable keys.

  Uses the nested `:configurable` (or `"configurable"`) map when present and the
  config itself otherwise, so `[thread_id: "t1"]` and
  `%{configurable: %{thread_id: "t1"}}` both return `%{"thread_id" => "t1"}`.
  """
  @spec configurable(config() | keyword()) :: map()
  defdelegate configurable(config), to: Normalization
end
