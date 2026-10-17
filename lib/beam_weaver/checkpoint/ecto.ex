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

  ## Options

    * `:repo` - the Ecto repo (required)
    * `:checkpoints_table`, `:writes_table` - table names, as given to the
      migration
    * `:prefix` - the Postgres schema that holds the tables, as given to the
      migration's `prefix:`
    * `:shallow?` - keep only the latest checkpoint of each thread
    * `:serialization` - a `BeamWeaver.Serialization.Config` or its options,
      such as a registry of your own structs or
      `codec: BeamWeaver.Serialization.Encrypted` with an `:encryption_key`.
      The database can't read encrypted metadata, so metadata filters and
      `BeamWeaver.Checkpoint.delete_for_runs/2` decrypt the checkpoints to
      find the matches.
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
  alias BeamWeaver.Checkpoint.Saver
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.ID
  alias BeamWeaver.Result

  defstruct repo: nil,
            query_module: Ecto.Adapters.SQL,
            checkpoints_table: "beam_weaver_checkpoints",
            writes_table: "beam_weaver_checkpoint_writes",
            prefix: nil,
            shallow?: false,
            serialization: %BeamWeaver.Serialization.Config{}

  @type t :: %__MODULE__{
          repo: module(),
          query_module: module(),
          checkpoints_table: String.t(),
          writes_table: String.t(),
          prefix: String.t() | nil,
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
      prefix: Keyword.get(opts, :prefix),
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
    Query.transaction(saver, fn ->
      put_in_current_transaction(saver, config, checkpoint, metadata, new_versions)
    end)
  end

  @impl true
  def put_many(%__MODULE__{} = saver, entries, _opts) do
    with :ok <- Batch.validate(entries) do
      Query.transaction(saver, fn ->
        with :ok <- lock_batch_owners(saver, entries),
             :ok <- ensure_new_batch_ids(saver, entries) do
          Result.traverse(entries, fn entry ->
            {:ok, config, checkpoint, metadata, versions, writes, write_opts} = Batch.entry(entry)

            with {:ok, next_config} <- put_in_current_transaction(saver, config, checkpoint, metadata, versions),
                 :ok <- put_batch_writes(saver, next_config, writes, write_opts),
                 do: {:ok, next_config}
          end)
        end
      end)
    end
  end

  @impl true
  defdelegate fork_at(saver, source_config, target_thread_id, opts), to: Lineage

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
          Map.get(checkpoint, "id") || Map.get(checkpoint, :id) || ID.uuidv7()

        with :ok <- Query.lock_owner(saver, thread_id, namespace),
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
            |> BeamWeaver.MapShape.put_present("checkpoint_target_ns", configurable["checkpoint_target_ns"])

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
             Config.stored_config(
               thread_id,
               namespace,
               checkpoint_id,
               checkpoint_map,
               configurable["checkpoint_target_ns"]
             )}
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

      rows =
        writes
        |> Enum.with_index()
        |> Result.traverse(fn {write, index} ->
          {channel, value} = Config.normalize_write(write)

          with {:ok, value} <- dump_json_value(saver, value) do
            {:ok,
             %{
               thread_id: thread_id,
               checkpoint_ns: namespace,
               checkpoint_id: checkpoint_id,
               task_id: task_id,
               write_index: index,
               channel: channel,
               value: Config.store_write_value(value),
               task_path: task_path
             }}
          end
        end)

      with {:ok, rows} <- rows, do: insert_write_rows(saver, rows)
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
    Query.transaction(saver, fn ->
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

  # Each read is a query, so the history's checkpoints are listed a page at
  # a time.
  @impl true
  def get_delta_channel_history(%__MODULE__{} = saver, config, channel_names, opts),
    do: DeltaHistory.get(saver, config, channel_names, Keyword.put_new(opts, :read_ahead, 8))

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
    |> Enum.map(&(&1 |> Batch.identity() |> Tuple.delete_at(2)))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.reduce_while(:ok, fn {thread_id, namespace}, :ok ->
      case Query.lock_owner(saver, thread_id, namespace) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp ensure_new_batch_ids(saver, entries) do
    requested =
      Enum.map(entries, fn entry ->
        {thread_id, checkpoint_ns, checkpoint_id} = Batch.identity(entry)
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

      rows =
        Result.traverse(writes, fn write ->
          with {:ok, value} <- dump_json_value(saver, write.value) do
            {:ok,
             %{
               thread_id: configurable["thread_id"],
               checkpoint_ns: Map.get(configurable, "checkpoint_ns", ""),
               checkpoint_id: configurable["checkpoint_id"],
               task_id: write.task_id,
               write_index: write.index,
               channel: to_string(write.channel),
               value: Config.store_write_value(value),
               task_path: write.path || ""
             }}
          end
        end)

      with {:ok, rows} <- rows, do: insert_write_rows(saver, rows)
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

  def dump_json_value(%__MODULE__{} = saver, value),
    do: BeamWeaver.Serialization.dump_value(value, serialization: saver.serialization)

  def load_json_value(%__MODULE__{} = saver, value),
    do: BeamWeaver.Serialization.load_value(value, serialization: saver.serialization)

  def load_json_value!(%__MODULE__{} = saver, value) do
    case load_json_value(saver, value) do
      {:ok, decoded} -> decoded
      {:error, %Error{} = error} -> raise ArgumentError, error.message
    end
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
