defmodule BeamWeaver.Checkpoint.Ecto do
  @moduledoc """
  Ecto/Postgres checkpoint saver.

  This adapter implements the same `BeamWeaver.Checkpoint.Saver` contract as
  `BeamWeaver.Checkpoint.ETS`. Create its database tables with
  `BeamWeaver.Migrations` from application-owned Ecto migrations.
  """

  @behaviour BeamWeaver.Checkpoint.Saver

  alias BeamWeaver.Checkpoint
  alias BeamWeaver.Checkpoint.Batch
  alias BeamWeaver.Checkpoint.DeltaHistory
  alias BeamWeaver.Checkpoint.Ecto.Config
  alias BeamWeaver.Checkpoint.Ecto.Listing
  alias BeamWeaver.Checkpoint.Ecto.Maintenance
  alias BeamWeaver.Checkpoint.Ecto.SQL
  alias BeamWeaver.Checkpoint.Lineage
  alias BeamWeaver.Checkpoint.PendingWrite
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
                 query(saver, checkpoint_upsert_sql(saver), [
                   thread_id,
                   namespace,
                   checkpoint_id,
                   parent_id,
                   stored_checkpoint,
                   stored_metadata,
                   commit_order
                 ]) do
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
            row = [thread_id, namespace, checkpoint_id, task_id, index, channel, value, task_path]
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

  defp query(%__MODULE__{} = saver, sql, params) do
    SQL.query(saver, sql, params)
  end

  defp latest_checkpoint_id(%__MODULE__{shallow?: true}, _thread, _namespace),
    do: {:ok, nil}

  defp latest_checkpoint_id(saver, thread_id, namespace),
    do: Listing.latest_checkpoint_id_result(saver, thread_id, namespace)

  defp checkpoint_upsert_sql(saver) do
    """
    INSERT INTO #{saver.checkpoints_table}
      (thread_id, checkpoint_ns, checkpoint_id, parent_checkpoint_id, checkpoint, metadata, commit_order)
    VALUES ($1, $2, $3, $4, $5, $6, $7)
    ON CONFLICT (thread_id, checkpoint_ns, checkpoint_id)
    DO UPDATE SET checkpoint = EXCLUDED.checkpoint, metadata = EXCLUDED.metadata
    """
  end

  defp insert_write_rows(_saver, []), do: :ok

  defp insert_write_rows(saver, rows) do
    rows
    |> Enum.chunk_every(1_000)
    |> Enum.reduce_while(:ok, fn chunk, :ok ->
      {values, params} = sql_values(chunk)

      sql = """
      INSERT INTO #{saver.writes_table}
        (thread_id, checkpoint_ns, checkpoint_id, task_id, write_index, channel, value, task_path)
      VALUES #{values}
      ON CONFLICT (thread_id, checkpoint_ns, checkpoint_id, task_id, write_index)
      DO UPDATE SET channel = EXCLUDED.channel, value = EXCLUDED.value,
                    task_path = EXCLUDED.task_path
      """

      case query(saver, sql, params) do
        {:ok, _result} -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp sql_values(rows) do
    values =
      rows
      |> Enum.with_index()
      |> Enum.map_join(", ", fn {_row, index} ->
        first = index * 8 + 1
        placeholders = Enum.map_join(first..(first + 7), ", ", &"$#{&1}")
        "(#{placeholders})"
      end)

    {values, Enum.flat_map(rows, & &1)}
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

    {threads, namespaces, checkpoint_ids} =
      Enum.reduce(keys, {[], [], []}, fn {thread, namespace, id}, {threads, namespaces, ids} ->
        {[thread | threads], [namespace | namespaces], [id | ids]}
      end)

    sql = """
    WITH requested(thread_id, checkpoint_ns, checkpoint_id) AS (
      SELECT * FROM unnest($1::text[], $2::text[], $3::text[])
    )
    SELECT 1
    FROM #{saver.checkpoints_table} AS checkpoints
    JOIN requested USING (thread_id, checkpoint_ns, checkpoint_id)
    LIMIT 1
    """

    params = [Enum.reverse(threads), Enum.reverse(namespaces), Enum.reverse(checkpoint_ids)]

    case query(saver, sql, params) do
      {:ok, %{rows: []}} -> :ok
      {:ok, %{rows: _rows}} -> {:error, Error.new(:checkpoint_conflict, "checkpoint identity already exists")}
      {:error, _reason} = error -> error
    end
  end

  defp put_batch_writes(saver, config, writes, opts) do
    if Enum.all?(writes, &match?(%PendingWrite{}, &1)) do
      configurable = Checkpoint.configurable(config)

      writes
      |> Enum.reduce_while({:ok, []}, fn write, {:ok, rows} ->
        case dump_json_value(saver, write.value) do
          {:ok, value} ->
            row = [
              configurable["thread_id"],
              Map.get(configurable, "checkpoint_ns", ""),
              configurable["checkpoint_id"],
              write.task_id,
              write.index,
              to_string(write.channel),
              value,
              write.path || ""
            ]

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
    case query(
           saver,
           "SELECT pg_advisory_xact_lock(hashtextextended($1, hashtext($2)::bigint))",
           [thread_id, namespace]
         ) do
      {:ok, _result} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp lock_owner(_saver, _thread_id, _namespace),
    do: {:error, Error.new(:invalid_checkpoint, "checkpoint config requires thread_id")}

  defp next_commit_order(saver, thread_id, namespace) do
    sql = """
    SELECT COALESCE(MAX(commit_order), 0) + 1
    FROM #{saver.checkpoints_table}
    WHERE thread_id = $1 AND checkpoint_ns = $2
    """

    case query(saver, sql, [thread_id, namespace]) do
      {:ok, %{rows: [[order]]}} -> {:ok, order}
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
    SQL.transaction(saver, fun)
  end

  defp maybe_delete_shallow_history(%__MODULE__{shallow?: false}, _thread_id, _namespace), do: :ok

  defp maybe_delete_shallow_history(%__MODULE__{} = saver, thread_id, namespace) do
    SQL.delete_shallow_history(saver, thread_id, namespace)
  end
end
