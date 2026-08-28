defmodule BeamWeaver.Checkpoint.Ecto do
  @moduledoc """
  Durable checkpoint saver for PostgreSQL and SQLite Ecto repositories.

  This adapter implements the same `BeamWeaver.Checkpoint.Saver` contract as
  `BeamWeaver.Checkpoint.ETS`. Create its database tables with
  `BeamWeaver.Migrations` from application-owned Ecto migrations. Applications
  using SQLite must add `ecto_sqlite3` themselves. BeamWeaver declares the
  adapter as optional, so PostgreSQL consumers are not forced to install it.

  Reads and writes use one Ecto query implementation for both databases. Only
  schema migration SQL and write serialization differ by adapter.
  """

  @behaviour BeamWeaver.Checkpoint.Saver

  import Ecto.Query

  alias BeamWeaver.Checkpoint
  alias BeamWeaver.Checkpoint.Batch
  alias BeamWeaver.Checkpoint.DeltaHistory
  alias BeamWeaver.Checkpoint.Ecto.Config
  alias BeamWeaver.Checkpoint.Ecto.Listing
  alias BeamWeaver.Checkpoint.Ecto.Maintenance
  alias BeamWeaver.Checkpoint.Ecto.Query
  alias BeamWeaver.Checkpoint.Lineage
  alias BeamWeaver.Checkpoint.PendingWrite
  alias BeamWeaver.Checkpoint.ResumeDelivery
  alias BeamWeaver.Checkpoint.ResumeDelivery.{CommitReceipt, StageReceipt}
  alias BeamWeaver.Checkpoint.Saver
  alias BeamWeaver.Core.Error

  defstruct repo: nil,
            query_module: Ecto.Adapters.SQL,
            checkpoints_table: "beam_weaver_checkpoints",
            writes_table: "beam_weaver_checkpoint_writes",
            shallow?: false,
            serialization: %BeamWeaver.Serialization.Config{}

  @type t :: %__MODULE__{
          repo: module(),
          query_module: module(),
          checkpoints_table: String.t(),
          writes_table: String.t(),
          shallow?: boolean(),
          serialization: BeamWeaver.Serialization.Config.t()
        }

  @spec new(keyword()) :: t()
  def new(opts) do
    %__MODULE__{
      repo: Keyword.fetch!(opts, :repo),
      query_module: Keyword.get(opts, :query_module, Ecto.Adapters.SQL),
      checkpoints_table: Keyword.get(opts, :checkpoints_table, "beam_weaver_checkpoints"),
      writes_table: Keyword.get(opts, :writes_table, "beam_weaver_checkpoint_writes"),
      shallow?: Keyword.get(opts, :shallow?, Keyword.get(opts, :shallow, false)),
      serialization: BeamWeaver.Serialization.Config.new(Keyword.get(opts, :serialization))
    }
  end

  @impl true
  def get_tuple(%__MODULE__{} = saver, config), do: Listing.get_tuple(saver, config)

  @impl true
  def fetch_tuple(%__MODULE__{} = saver, config), do: Listing.fetch_tuple(saver, config)

  @impl true
  def list(%__MODULE__{} = saver, config, opts), do: Listing.list(saver, config, opts)

  @impl true
  def list_result(%__MODULE__{} = saver, config, opts), do: Listing.list_result(saver, config, opts)

  @impl true
  def put(%__MODULE__{} = saver, config, checkpoint, metadata, new_versions) do
    transaction(saver, fn ->
      put_in_current_transaction(saver, config, checkpoint, metadata, new_versions)
    end)
  end

  @impl true
  def put_many(%__MODULE__{} = saver, entries, _opts) do
    with :ok <- Batch.validate(entries) do
      transaction(saver, fn ->
        with :ok <- lock_batch_owners(saver, entries),
             :ok <- ensure_new_batch_ids(saver, entries) do
          Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, configs} ->
            with {:ok, config, checkpoint, metadata, versions, writes, write_opts} <-
                   Batch.entry(entry),
                 {:ok, next_config} <-
                   put_in_current_transaction(saver, config, checkpoint, metadata, versions),
                 :ok <- put_batch_writes(saver, next_config, writes, write_opts) do
              {:cont, {:ok, [next_config | configs]}}
            else
              {:error, _reason} = error -> {:halt, error}
            end
          end)
          |> case do
            {:ok, configs} -> {:ok, Enum.reverse(configs)}
            {:error, _reason} = error -> error
          end
        end
      end)
    end
  end

  @impl true
  def fork_at(%__MODULE__{} = saver, source_config, target_thread_id, opts) do
    with {:ok, lineage} <- Lineage.collect(saver, source_config, opts),
         entries <- Batch.fork_entries(lineage, target_thread_id),
         {:ok, configs} <- put_many(saver, entries, []) do
      {:ok, List.last(configs)}
    end
  end

  defp put_in_current_transaction(
         %__MODULE__{} = saver,
         config,
         checkpoint,
         metadata,
         new_versions
       ) do
    configurable = Checkpoint.configurable(config)

    case configurable["thread_id"] do
      thread_id when is_binary(thread_id) ->
        namespace = Map.get(configurable, "checkpoint_ns", "")

        checkpoint_id =
          Map.get(checkpoint, "id") || Map.get(checkpoint, :id) || Config.generated_id()

        with :ok <- lock_owner(saver, thread_id, namespace),
             {:ok, latest_id} <- latest_checkpoint_id(saver, thread_id, namespace),
             {:ok, commit_order} <- next_commit_order(saver, thread_id, namespace) do
          parent_id =
            if saver.shallow?, do: nil, else: Map.get(configurable, "checkpoint_id") || latest_id

          parent_id = if parent_id == checkpoint_id, do: nil, else: parent_id
          checkpoint_map = Config.checkpoint_map(configurable, namespace, checkpoint_id)

          checkpoint =
            checkpoint
            |> Config.stringify_keys()
            |> Map.put_new("id", checkpoint_id)
            |> Map.put_new("ts", DateTime.utc_now() |> DateTime.to_iso8601())
            |> Map.put_new("channel_versions", Config.stringify_keys(new_versions || %{}))
            |> Map.put_new("checkpoint_map", checkpoint_map)
            |> Config.put_checkpoint_target_namespace(configurable)

          with {:ok, stored_checkpoint} <- dump_json_value(saver, checkpoint),
               {:ok, stored_metadata} <- dump_json_value(saver, Config.stringify_keys(metadata || %{})),
               :ok <- maybe_delete_shallow_history(saver, thread_id, namespace),
               {:ok, _result} <-
                 Query.insert_all(
                   saver,
                   Query.checkpoints(saver),
                   [
                     %{
                       thread_id: thread_id,
                       checkpoint_ns: namespace,
                       checkpoint_id: checkpoint_id,
                       parent_checkpoint_id: parent_id,
                       checkpoint: stored_checkpoint,
                       metadata: stored_metadata,
                       commit_order: commit_order
                     }
                   ],
                   on_conflict: {:replace, [:checkpoint, :metadata]},
                   conflict_target: [:thread_id, :checkpoint_ns, :checkpoint_id]
                 ) do
            {:ok,
             %{
               "configurable" => %{
                 "thread_id" => thread_id,
                 "checkpoint_ns" => namespace,
                 "checkpoint_id" => checkpoint_id,
                 "checkpoint_map" => checkpoint_map
               }
             }
             |> Config.put_target_namespace(configurable)}
          end
        end

      _other ->
        {:error, {:missing_configurable, "thread_id"}}
    end
  end

  @impl true
  def put_writes(%__MODULE__{} = saver, config, writes, task_id, task_path) do
    configurable = Checkpoint.configurable(config)

    with thread_id when is_binary(thread_id) <- configurable["thread_id"],
         checkpoint_id when is_binary(checkpoint_id) <- configurable["checkpoint_id"] do
      namespace = Map.get(configurable, "checkpoint_ns", "")

      writes
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, []}, fn {write, index}, {:ok, rows} ->
        {channel, value} = Config.normalize_write(write)

        case dump_json_value(saver, value) do
          {:ok, value} ->
            row = %{
              thread_id: thread_id,
              checkpoint_ns: namespace,
              checkpoint_id: checkpoint_id,
              task_id: task_id,
              write_index: index,
              channel: channel,
              value: Config.store_write_value(value),
              task_path: task_path
            }

            {:cont, {:ok, [row | rows]}}

          {:error, _reason} = error ->
            {:halt, error}
        end
      end)
      |> case do
        {:ok, rows} -> insert_write_rows(saver, Enum.reverse(rows))
        {:error, _reason} = error -> error
      end
    else
      _other -> {:error, {:missing_configurable, "thread_id/checkpoint_id"}}
    end
  end

  @impl true
  def put_checkpoint_with_writes(
        %__MODULE__{} = saver,
        config,
        checkpoint,
        metadata,
        new_versions,
        writes,
        opts
      ) do
    transaction(saver, fn ->
      with {:ok, next_config} <-
             put_in_current_transaction(saver, config, checkpoint, metadata, new_versions),
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
    end)
  end

  @impl true
  def continue_staged(
        %__MODULE__{} = saver,
        %StageReceipt{delivery: %ResumeDelivery{}, source_config: source_config} = stage
      )
      when is_map(source_config) or is_list(source_config) do
    configurable = Checkpoint.configurable(stage.source_config)
    thread_id = configurable["thread_id"]
    namespace = Map.get(configurable, "checkpoint_ns", "")
    source_id = stage.delivery.source_checkpoint_id
    result_id = ResumeDelivery.result_checkpoint_id(stage.delivery)
    result_config = exact_config(stage.source_config, result_id)

    transaction(saver, fn ->
      with :ok <- Checkpoint.verify_stage_receipt(stage),
           true <- is_binary(thread_id),
           :ok <- lock_owner(saver, thread_id, namespace) do
        case Listing.fetch_tuple(saver, result_config) do
          {:ok, %{checkpoint: checkpoint}} ->
            if committed_delivery_present?(checkpoint, stage) do
              committed_receipt(saver, stage, result_config)
            else
              {:error, Error.new(:invalid_resume_receipt, "resume checkpoint is missing delivery")}
            end

          {:ok, nil} ->
            with {:ok, latest_id} <- latest_checkpoint_id(saver, thread_id, namespace) do
              if latest_id == source_id do
                commit_staged_resume(saver, stage, result_id)
              else
                {:error, Error.new(:checkpoint_conflict, "resume source checkpoint is not current")}
              end
            end

          {:error, _reason} = error ->
            error
        end
      else
        false -> {:error, Error.new(:invalid_checkpoint, "checkpoint config requires thread_id")}
        {:error, _reason} = error -> error
      end
    end)
  end

  def continue_staged(%__MODULE__{}, %StageReceipt{}),
    do: {:error, Error.new(:invalid_resume_receipt, "resume stage receipt does not verify")}

  @impl true
  def get_delta_channel_history(%__MODULE__{} = saver, config, channel_names, opts) do
    DeltaHistory.get(saver, config, channel_names, opts)
  end

  @impl true
  def delete_thread(%__MODULE__{} = saver, thread_id),
    do: Maintenance.delete_thread(saver, thread_id)

  @impl true
  def delete_for_runs(%__MODULE__{} = saver, run_ids),
    do: Maintenance.delete_for_runs(saver, run_ids)

  @impl true
  def copy_thread(%__MODULE__{} = saver, source_thread_id, target_thread_id),
    do: Maintenance.copy_thread(saver, source_thread_id, target_thread_id)

  @impl true
  def prune(%__MODULE__{} = saver, thread_ids, opts),
    do: Maintenance.prune(saver, thread_ids, opts)

  @impl true
  def next_version(_saver, current, _channel), do: Saver.default_next_version(current)

  defp latest_checkpoint_id(%__MODULE__{shallow?: true}, _thread, _namespace),
    do: {:ok, nil}

  defp latest_checkpoint_id(saver, thread_id, namespace),
    do: Listing.latest_checkpoint_id_result(saver, thread_id, namespace)

  defp commit_staged_resume(saver, %StageReceipt{} = stage, result_id) do
    with {:ok, %{checkpoint: source_checkpoint} = source_tuple} <-
           Listing.fetch_tuple(saver, stage.source_config),
         true <- staged_resume_present?(source_tuple, stage),
         checkpoint <- resumed_checkpoint(saver, source_checkpoint, stage, result_id),
         versions <- Map.get(checkpoint, "channel_versions", %{}),
         {:ok, result_config} <-
           put_in_current_transaction(
             saver,
             stage.source_config,
             checkpoint,
             %{
               "source" => "resume_delivery",
               "delivery_id" => stage.delivery.delivery_id,
               "claim_hash" => stage.claim_hash
             },
             versions
           ),
         :ok <- copy_unrelated_pending_writes(saver, source_tuple, result_config, stage),
         {:ok, receipt} <- committed_receipt(saver, stage, result_config) do
      {:ok, receipt}
    else
      false ->
        {:error, Error.new(:resume_delivery_not_staged, "resume delivery was not staged")}

      {:ok, _missing} ->
        {:error, Error.new(:resume_delivery_not_staged, "resume source checkpoint is missing")}

      {:error, _reason} = error ->
        error
    end
  end

  defp committed_receipt(saver, %StageReceipt{} = stage, result_config) do
    with {:ok, %{checkpoint: checkpoint}} <- Listing.fetch_tuple(saver, result_config),
         true <- committed_delivery_present?(checkpoint, stage) do
      checkpoint_hash = Checkpoint.resume_checkpoint_hash(checkpoint)

      receipt = %CommitReceipt{
        delivery_id: stage.delivery.delivery_id,
        source_checkpoint_id: stage.delivery.source_checkpoint_id,
        resulting_config: result_config,
        resulting_checkpoint_id: checkpoint["id"],
        claim_hash: stage.claim_hash,
        checkpoint_hash: checkpoint_hash,
        receipt_hash: ""
      }

      receipt = %{receipt | receipt_hash: Checkpoint.commit_receipt_hash(receipt)}
      {:ok, receipt}
    else
      false -> {:error, Error.new(:invalid_resume_receipt, "resume checkpoint is missing delivery")}
      {:ok, _missing} -> {:error, Error.new(:invalid_resume_receipt, "resume checkpoint is missing")}
      {:error, _reason} = error -> error
    end
  end

  defp resumed_checkpoint(saver, source_checkpoint, %StageReceipt{} = stage, result_id) do
    channel = Checkpoint.resume_channel()
    channel_values = Map.get(source_checkpoint, "channel_values", %{})

    delivered = %{
      "delivery_id" => stage.delivery.delivery_id,
      "source_ordinal" => stage.delivery.source_ordinal,
      "claim_hash" => stage.claim_hash,
      "delivery" => ResumeDelivery.to_map(stage.delivery)
    }

    deliveries = List.wrap(Map.get(channel_values, channel)) ++ [delivered]

    source_checkpoint
    |> Map.drop(["ts", "checkpoint_map"])
    |> Map.put("id", result_id)
    |> Map.put("channel_values", Map.put(channel_values, channel, deliveries))
    |> update_in(["channel_versions"], fn versions ->
      versions = versions || %{}
      Map.put(versions, channel, Saver.next_version(saver, Map.get(versions, channel), channel))
    end)
  end

  defp staged_resume_present?(tuple, %StageReceipt{} = stage) do
    Enum.any?(Map.get(tuple, :pending_write_records, []), fn write ->
      write.task_id == ResumeDelivery.task_id(stage.delivery) and
        write.channel == Checkpoint.resume_channel() and
        write.value == ResumeDelivery.to_map(stage.delivery)
    end)
  end

  defp committed_delivery_present?(checkpoint, %StageReceipt{} = stage) do
    checkpoint
    |> get_in(["channel_values", Checkpoint.resume_channel()])
    |> List.wrap()
    |> Enum.any?(fn delivered ->
      delivered["delivery_id"] == stage.delivery.delivery_id and
        delivered["claim_hash"] == stage.claim_hash and
        delivered["delivery"] == ResumeDelivery.to_map(stage.delivery)
    end)
  end

  defp copy_unrelated_pending_writes(saver, source_tuple, result_config, stage) do
    source_tuple
    |> Map.get(:pending_write_records, [])
    |> Enum.reject(fn write ->
      write.task_id == ResumeDelivery.task_id(stage.delivery) and
        write.channel == Checkpoint.resume_channel()
    end)
    |> Enum.group_by(fn write -> {write.task_id, write.path} end)
    |> Enum.sort_by(fn {{task_id, path}, _writes} -> {task_id, path} end)
    |> Enum.reduce_while(:ok, fn {{task_id, path}, writes}, :ok ->
      ordered_writes =
        writes
        |> Enum.sort_by(& &1.index)
        |> Enum.map(&{&1.channel, &1.value})

      case put_writes(saver, result_config, ordered_writes, task_id, path) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp exact_config(config, checkpoint_id) do
    configurable = Checkpoint.configurable(config)
    namespace = Map.get(configurable, "checkpoint_ns", "")

    config
    |> config_map()
    |> Map.delete(:configurable)
    |> Map.put(
      "configurable",
      configurable
      |> Map.put("checkpoint_id", checkpoint_id)
      |> Map.put("checkpoint_map", Config.checkpoint_map(configurable, namespace, checkpoint_id))
    )
  end

  defp config_map(config) when is_list(config), do: Map.new(config)
  defp config_map(config) when is_map(config), do: config

  defp insert_write_rows(_saver, []), do: :ok

  defp insert_write_rows(saver, rows) do
    rows
    |> Enum.chunk_every(1_000)
    |> Enum.reduce_while(:ok, fn chunk, :ok ->
      case Query.insert_all(saver, Query.writes(saver), chunk,
             on_conflict: {:replace, [:channel, :value, :task_path]},
             conflict_target: [
               :thread_id,
               :checkpoint_ns,
               :checkpoint_id,
               :task_id,
               :write_index
             ]
           ) do
        {:ok, _result} -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp lock_batch_owners(saver, entries) do
    entries
    |> Enum.reduce_while({:ok, MapSet.new()}, fn entry, {:ok, owners} ->
      case Batch.entry(entry) do
        {:ok, config, _checkpoint, _metadata, _versions, _writes, _opts} ->
          configurable = Checkpoint.configurable(config)
          owner = {configurable["thread_id"], Map.get(configurable, "checkpoint_ns", "")}
          {:cont, {:ok, MapSet.put(owners, owner)}}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, owners} ->
        owners
        |> Enum.sort()
        |> Enum.reduce_while(:ok, fn {thread_id, namespace}, :ok ->
          case lock_owner(saver, thread_id, namespace) do
            :ok -> {:cont, :ok}
            {:error, _reason} = error -> {:halt, error}
          end
        end)

      {:error, _reason} = error ->
        error
    end
  end

  defp ensure_new_batch_ids(saver, entries) do
    keys =
      Enum.map(entries, fn entry ->
        {:ok, config, checkpoint, _metadata, _versions, _writes, _opts} = Batch.entry(entry)
        configurable = Checkpoint.configurable(config)

        {
          configurable["thread_id"],
          Map.get(configurable, "checkpoint_ns", ""),
          Map.get(checkpoint, :id) || Map.fetch!(checkpoint, "id")
        }
      end)

    requested =
      Enum.map(keys, fn {thread_id, checkpoint_ns, checkpoint_id} ->
        %{thread_id: thread_id, checkpoint_ns: checkpoint_ns, checkpoint_id: checkpoint_id}
      end)

    query =
      from(checkpoint in Query.checkpoints(saver),
        join:
          requested in values(requested, %{
            thread_id: :string,
            checkpoint_ns: :string,
            checkpoint_id: :string
          }),
        on:
          checkpoint.thread_id == requested.thread_id and
            checkpoint.checkpoint_ns == requested.checkpoint_ns and
            checkpoint.checkpoint_id == requested.checkpoint_id,
        limit: 1,
        select: checkpoint.checkpoint_id
      )

    case Query.one(saver, query) do
      {:ok, nil} ->
        :ok

      {:ok, _checkpoint_id} ->
        {:error, Error.new(:checkpoint_conflict, "checkpoint identity already exists")}

      {:error, _reason} = error ->
        error
    end
  end

  defp put_batch_writes(saver, config, writes, opts) do
    if Enum.all?(writes, &match?(%PendingWrite{}, &1)) do
      configurable = Checkpoint.configurable(config)

      writes
      |> Enum.reduce_while({:ok, []}, fn write, {:ok, rows} ->
        case dump_json_value(saver, write.value) do
          {:ok, value} ->
            row = %{
              thread_id: configurable["thread_id"],
              checkpoint_ns: Map.get(configurable, "checkpoint_ns", ""),
              checkpoint_id: configurable["checkpoint_id"],
              task_id: write.task_id,
              write_index: write.index,
              channel: to_string(write.channel),
              value: Config.store_write_value(value),
              task_path: write.path || ""
            }

            {:cont, {:ok, [row | rows]}}

          {:error, _reason} = error ->
            {:halt, error}
        end
      end)
      |> case do
        {:ok, rows} -> insert_write_rows(saver, Enum.reverse(rows))
        {:error, _reason} = error -> error
      end
    else
      put_writes(
        saver,
        config,
        writes,
        Keyword.get(opts, :task_id, "checkpoint"),
        Keyword.get(opts, :task_path, "")
      )
    end
  end

  defp lock_owner(saver, thread_id, namespace) when is_binary(thread_id) do
    Query.lock_owner(saver, thread_id, namespace)
  end

  defp lock_owner(_saver, _thread_id, _namespace),
    do: {:error, Error.new(:invalid_checkpoint, "checkpoint config requires thread_id")}

  defp next_commit_order(saver, thread_id, namespace) do
    query =
      from(checkpoint in Query.checkpoints(saver),
        where: checkpoint.thread_id == ^thread_id and checkpoint.checkpoint_ns == ^namespace,
        select: max(checkpoint.commit_order)
      )

    case Query.one(saver, query) do
      {:ok, nil} -> {:ok, 1}
      {:ok, order} -> {:ok, order + 1}
      {:error, _reason} = error -> error
    end
  end

  def dump_json_value(%__MODULE__{} = saver, value) do
    BeamWeaver.Adapter.ValueCodec.dump_json_value(value, serialization: saver.serialization)
  end

  def load_json_value(%__MODULE__{} = saver, value) do
    BeamWeaver.Adapter.ValueCodec.load_json_value(value, serialization: saver.serialization)
  end

  def load_json_value!(%__MODULE__{} = saver, value) do
    case load_json_value(saver, value) do
      {:ok, decoded} -> decoded
      {:error, %Error{} = error} -> raise ArgumentError, error.message
    end
  end

  defp transaction(%__MODULE__{} = saver, fun) do
    Query.transaction(saver, fun)
  end

  defp maybe_delete_shallow_history(%__MODULE__{shallow?: false}, _thread_id, _namespace), do: :ok

  defp maybe_delete_shallow_history(%__MODULE__{} = saver, thread_id, namespace) do
    with {:ok, _result} <-
           Query.delete_all(
             saver,
             from(write in Query.writes(saver),
               where: write.thread_id == ^thread_id and write.checkpoint_ns == ^namespace
             )
           ),
         {:ok, _result} <-
           Query.delete_all(
             saver,
             from(checkpoint in Query.checkpoints(saver),
               where: checkpoint.thread_id == ^thread_id and checkpoint.checkpoint_ns == ^namespace
             )
           ) do
      :ok
    end
  end
end
