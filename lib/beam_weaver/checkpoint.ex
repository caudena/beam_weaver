defmodule BeamWeaver.Checkpoint do
  @moduledoc """
  Public helpers for graph checkpoint savers.

  Checkpoint savers are adapter structs that implement
  `BeamWeaver.Checkpoint.Saver`. The graph runtime depends on this contract, not
  on ETS, Ecto, or any other backend-specific module.
  """

  alias BeamWeaver.Checkpoint.Normalization
  alias BeamWeaver.Checkpoint.Batch
  alias BeamWeaver.Checkpoint.Record
  alias BeamWeaver.Checkpoint.ResumeDelivery
  alias BeamWeaver.Checkpoint.ResumeDelivery.{CommitReceipt, StageReceipt}
  alias BeamWeaver.Checkpoint.Saver
  alias BeamWeaver.Checkpoint.Telemetry
  alias BeamWeaver.Core.Async
  alias BeamWeaver.Core.Error

  @type saver :: struct()
  @type config :: map()
  @type checkpoint :: map()
  @type metadata :: map()
  @type versions :: map()
  @type writes :: [{String.t(), term()} | {String.t(), String.t(), term()}]

  @resume_channel "__beam_weaver_resume_delivery__"

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
        {:error,
         Error.new(
           :atomic_checkpoint_write_unsupported,
           "checkpoint saver does not support atomic checkpoint and write persistence",
           %{saver: inspect(module)}
         )}

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

  @doc """
  Durably stages one exact parent-lane resume delivery against an exact source
  checkpoint.

  Staging adds one idempotent pending write and does not consume or replace any
  other pending writes.
  """
  @spec stage_resume(saver(), config(), ResumeDelivery.t()) ::
          {:ok, StageReceipt.t()} | {:error, term()}
  def stage_resume(saver, config, %ResumeDelivery{} = delivery) do
    source_config = exact_checkpoint_config(config, delivery.source_checkpoint_id)

    with {:ok, %{checkpoint: %{"id" => source_id}}} when source_id == delivery.source_checkpoint_id <-
           fetch_tuple(saver, source_config),
         :ok <-
           put_writes(
             saver,
             source_config,
             [{@resume_channel, ResumeDelivery.to_map(delivery)}],
             ResumeDelivery.task_id(delivery),
             "resume:#{delivery.source_ordinal}"
           ),
         {:ok, tuple} <- fetch_tuple(saver, source_config),
         true <- staged_delivery?(tuple, delivery) do
      claim_hash = ResumeDelivery.claim_hash(delivery)

      {:ok,
       %StageReceipt{
         delivery: delivery,
         source_config: source_config,
         claim_hash: claim_hash,
         receipt_hash: stage_receipt_hash(delivery, source_config)
       }}
    else
      false ->
        {:error, Error.new(:resume_delivery_not_staged, "resume delivery was not staged")}

      {:ok, _tuple} ->
        {:error, Error.new(:checkpoint_conflict, "resume source checkpoint is not current")}

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Atomically consumes a staged resume delivery into the next checkpoint.

  Only savers implementing the strict callback are accepted; there is no
  sequential fallback.
  """
  @spec continue_staged(saver(), StageReceipt.t()) ::
          {:ok, CommitReceipt.t()} | {:error, term()}
  def continue_staged(saver, %StageReceipt{} = stage) do
    module = saver.__struct__

    with :ok <- verify_stage_receipt(stage) do
      if function_exported?(module, :continue_staged, 2) do
        module.continue_staged(saver, stage)
      else
        {:error,
         Error.new(
           :strict_resume_unsupported,
           "checkpoint saver does not support strict resume delivery"
         )}
      end
    end
  end

  @doc false
  @spec verify_stage_receipt(StageReceipt.t()) :: :ok | {:error, Error.t()}
  def verify_stage_receipt(%StageReceipt{delivery: %ResumeDelivery{}, source_config: source_config} = stage)
      when is_map(source_config) or is_list(source_config) do
    configurable = configurable(stage.source_config)

    with {:ok, delivery} <- ResumeDelivery.new(ResumeDelivery.to_map(stage.delivery)),
         true <- delivery == stage.delivery,
         true <- is_binary(configurable["thread_id"]) and configurable["thread_id"] != "",
         true <- configurable["checkpoint_id"] == stage.delivery.source_checkpoint_id,
         true <- stage.claim_hash == ResumeDelivery.claim_hash(stage.delivery),
         true <- stage.receipt_hash == stage_receipt_hash(stage.delivery, stage.source_config) do
      :ok
    else
      _invalid -> {:error, Error.new(:invalid_resume_receipt, "resume stage receipt does not verify")}
    end
  end

  def verify_stage_receipt(%StageReceipt{}),
    do: {:error, Error.new(:invalid_resume_receipt, "resume stage receipt does not verify")}

  @doc false
  def stage_receipt_hash(%ResumeDelivery{} = delivery, source_config) do
    BeamWeaver.Compaction.Canonical.hash(%{
      "schema_version" => 1,
      "phase" => "staged",
      "delivery_id" => delivery.delivery_id,
      "source_checkpoint_id" => delivery.source_checkpoint_id,
      "claim_hash" => ResumeDelivery.claim_hash(delivery),
      "source_owner" => checkpoint_owner(source_config)
    })
  end

  @doc "Verifies a strict resume commit receipt against its stored checkpoint."
  @spec verify_resume_receipt(saver(), CommitReceipt.t()) :: :ok | {:error, term()}
  def verify_resume_receipt(saver, %CommitReceipt{} = receipt) do
    with {:ok, %{checkpoint: checkpoint}} <- fetch_tuple(saver, receipt.resulting_config),
         true <- checkpoint["id"] == receipt.resulting_checkpoint_id,
         true <- resume_checkpoint_hash(checkpoint) == receipt.checkpoint_hash,
         true <- receipt_delivery?(checkpoint, receipt.delivery_id, receipt.claim_hash),
         true <- commit_receipt_hash(receipt) == receipt.receipt_hash do
      :ok
    else
      false -> {:error, Error.new(:invalid_resume_receipt, "resume receipt does not verify")}
      {:ok, _missing} -> {:error, Error.new(:invalid_resume_receipt, "resume checkpoint is missing")}
      {:error, _reason} = error -> error
    end
  end

  @doc false
  def resume_channel, do: @resume_channel

  @doc false
  def resume_checkpoint_hash(checkpoint) when is_map(checkpoint) do
    BeamWeaver.Compaction.Canonical.hash(%{
      "schema_version" => 1,
      "checkpoint_id" => checkpoint["id"],
      "channel_version" => get_in(checkpoint, ["channel_versions", @resume_channel]),
      "deliveries" => get_in(checkpoint, ["channel_values", @resume_channel]) |> List.wrap()
    })
  end

  @doc false
  def commit_receipt_hash(%CommitReceipt{} = receipt) do
    BeamWeaver.Compaction.Canonical.hash(%{
      "schema_version" => 1,
      "phase" => "committed",
      "delivery_id" => receipt.delivery_id,
      "source_checkpoint_id" => receipt.source_checkpoint_id,
      "resulting_checkpoint_id" => receipt.resulting_checkpoint_id,
      "claim_hash" => receipt.claim_hash,
      "checkpoint_hash" => receipt.checkpoint_hash,
      "resulting_owner" => checkpoint_owner(receipt.resulting_config)
    })
  end

  defp exact_checkpoint_config(config, checkpoint_id) do
    configurable = configurable(config)

    config
    |> config_map()
    |> Map.delete(:configurable)
    |> Map.put("configurable", Map.put(configurable, "checkpoint_id", checkpoint_id))
  end

  defp config_map(config) when is_list(config), do: Map.new(config)
  defp config_map(config) when is_map(config), do: config

  defp staged_delivery?(tuple, delivery) do
    Enum.any?(Map.get(tuple, :pending_write_records, []), fn record ->
      record.task_id == ResumeDelivery.task_id(delivery) and record.channel == @resume_channel and
        record.value == ResumeDelivery.to_map(delivery)
    end)
  end

  defp receipt_delivery?(checkpoint, delivery_id, claim_hash) do
    checkpoint
    |> get_in(["channel_values", @resume_channel])
    |> List.wrap()
    |> Enum.any?(fn value ->
      value["delivery_id"] == delivery_id and value["claim_hash"] == claim_hash
    end)
  end

  defp checkpoint_owner(config) do
    config = configurable(config)

    %{
      "thread_id" => config["thread_id"],
      "checkpoint_namespace" => Map.get(config, "checkpoint_ns", "")
    }
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
    with true <- is_binary(target_thread_id) and target_thread_id != "",
         {:ok, module} <- required_callback(saver, :fork_at, 4) do
      module.fork_at(saver, source_config, target_thread_id, opts)
    else
      false ->
        {:error, Error.new(:invalid_checkpoint_fork, "target thread id is required")}

      {:error, _error} = error ->
        error
    end
  end

  defp checkpoint_read(saver, callback, args, fallback) do
    module = saver.__struct__

    if function_exported?(module, callback, length(args) + 1) do
      checkpoint_read(fn -> apply(module, callback, [saver | args]) end)
    else
      checkpoint_read(fallback)
    end
  end

  defp required_callback(saver, callback, arity) do
    module = saver.__struct__

    if function_exported?(module, callback, arity) do
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
