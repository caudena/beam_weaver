defmodule BeamWeaver.Checkpoint.Ecto do
  @moduledoc """
  Ecto/Postgres checkpoint saver.

  This adapter implements the same `BeamWeaver.Checkpoint.Saver` contract as
  `BeamWeaver.Checkpoint.ETS`. Create its database tables with
  `BeamWeaver.Migrations` from application-owned Ecto migrations.
  """

  @behaviour BeamWeaver.Checkpoint.Saver

  alias BeamWeaver.Checkpoint
  alias BeamWeaver.Checkpoint.DeltaHistory
  alias BeamWeaver.Checkpoint.Ecto.Config
  alias BeamWeaver.Checkpoint.Ecto.Listing
  alias BeamWeaver.Checkpoint.Ecto.Maintenance
  alias BeamWeaver.Checkpoint.Ecto.SQL
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
  def list(%__MODULE__{} = saver, config, opts), do: Listing.list(saver, config, opts)

  @impl true
  def put(%__MODULE__{} = saver, config, checkpoint, metadata, new_versions) do
    if saver.shallow? do
      transaction(saver, fn ->
        put_in_current_transaction(saver, config, checkpoint, metadata, new_versions)
      end)
    else
      put_in_current_transaction(saver, config, checkpoint, metadata, new_versions)
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

        parent_id =
          if saver.shallow? do
            nil
          else
            Map.get(configurable, "checkpoint_id") ||
              Listing.latest_checkpoint_id(saver, thread_id, namespace)
          end

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

        sql = """
        INSERT INTO #{saver.checkpoints_table}
          (thread_id, checkpoint_ns, checkpoint_id, parent_checkpoint_id, checkpoint, metadata)
        VALUES ($1, $2, $3, $4, $5, $6)
        ON CONFLICT (thread_id, checkpoint_ns, checkpoint_id)
        DO UPDATE SET checkpoint = EXCLUDED.checkpoint, metadata = EXCLUDED.metadata
        """

        with {:ok, stored_checkpoint} <- dump_json_value(saver, checkpoint),
             {:ok, stored_metadata} <- dump_json_value(saver, Config.stringify_keys(metadata || %{})),
             :ok <- maybe_delete_shallow_history(saver, thread_id, namespace),
             {:ok, _result} <-
               query(saver, sql, [
                 thread_id,
                 namespace,
                 checkpoint_id,
                 parent_id,
                 stored_checkpoint,
                 stored_metadata
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
        else
          error ->
            error
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

      Enum.reduce_while(Enum.with_index(writes), :ok, fn {write, index}, :ok ->
        {channel, value} = Config.normalize_write(write)

        sql = """
        INSERT INTO #{saver.writes_table}
          (thread_id, checkpoint_ns, checkpoint_id, task_id, write_index, channel, value, task_path)
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
        ON CONFLICT (thread_id, checkpoint_ns, checkpoint_id, task_id, write_index)
        DO UPDATE SET channel = EXCLUDED.channel, value = EXCLUDED.value, task_path = EXCLUDED.task_path
        """

        with {:ok, stored_value} <- dump_json_value(saver, value),
             {:ok, _result} <-
               query(saver, sql, [
                 thread_id,
                 namespace,
                 checkpoint_id,
                 task_id,
                 index,
                 channel,
                 stored_value,
                 task_path
               ]) do
          {:cont, :ok}
        else
          error -> {:halt, error}
        end
      end)
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
