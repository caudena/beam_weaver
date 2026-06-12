defmodule BeamWeaver.Checkpoint.ETS do
  @moduledoc """
  ETS implementation of `BeamWeaver.Checkpoint.Saver`.

  This adapter is intended for tests, local workflows, and lightweight
  supervised deployments. It uses the same saver contract as the Ecto/Postgres
  adapter, so graph and agent code never branch on storage backend.
  """

  @behaviour BeamWeaver.Checkpoint.Saver

  alias BeamWeaver.Checkpoint
  alias BeamWeaver.Checkpoint.DeltaCompaction
  alias BeamWeaver.Checkpoint.DeltaHistory
  alias BeamWeaver.Checkpoint.PendingWrite
  alias BeamWeaver.Checkpoint.Saver

  defstruct [:checkpoints, :writes, :counter]

  @type t :: %__MODULE__{
          checkpoints: :ets.tid(),
          writes: :ets.tid(),
          counter: :ets.tid()
        }

  @doc """
  Creates an in-memory checkpoint saver.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    visibility = Keyword.get(opts, :visibility, :public)

    %__MODULE__{
      checkpoints: :ets.new(:beam_weaver_checkpoints, [visibility, :ordered_set]),
      writes: :ets.new(:beam_weaver_checkpoint_writes, [visibility, :ordered_set]),
      counter: :ets.new(:beam_weaver_checkpoint_counter, [visibility, :set])
    }
  end

  @impl true
  def get_tuple(%__MODULE__{} = saver, config) do
    configurable = Checkpoint.configurable(config)
    thread_id = configurable["thread_id"]
    namespace = Map.get(configurable, "checkpoint_ns", "")
    checkpoint_id = Map.get(configurable, "checkpoint_id")

    with true <- is_binary(thread_id),
         {:ok, id} <- resolve_checkpoint_id(saver, thread_id, namespace, checkpoint_id),
         [{_key, record}] <- lookup_checkpoint(saver, thread_id, namespace, id) do
      put_pending_writes(saver, record)
    else
      _other -> nil
    end
  end

  @impl true
  def list(%__MODULE__{} = saver, config, opts) do
    filter = Keyword.get(opts, :filter, %{})
    before_config = Keyword.get(opts, :before)
    limit = Keyword.get(opts, :limit)
    configurable = if config, do: Checkpoint.configurable(config), else: %{}
    before_id = before_checkpoint_id(before_config)

    saver.checkpoints
    |> :ets.tab2list()
    |> Enum.map(fn {_key, record} -> record end)
    |> Enum.filter(&matches_config?(&1, configurable))
    |> Enum.filter(&matches_filter?(&1, filter))
    |> Enum.filter(&before_checkpoint?(&1, before_id))
    |> Enum.sort_by(fn record -> record.checkpoint["id"] end, :desc)
    |> maybe_take(limit)
    |> Enum.map(&put_pending_writes(saver, &1))
  end

  @impl true
  def put(%__MODULE__{} = saver, config, checkpoint, metadata, new_versions) do
    configurable = Checkpoint.configurable(config)
    thread_id = Map.get(configurable, "thread_id")

    if is_nil(thread_id) or thread_id == "" do
      {:error, {:missing_configurable, "thread_id"}}
    else
      namespace = Map.get(configurable, "checkpoint_ns", "")
      checkpoint_id = checkpoint_id(saver, checkpoint)

      parent_id =
        Map.get(configurable, "checkpoint_id") ||
          latest_checkpoint_id(saver, thread_id, namespace)

      parent_id = if parent_id == checkpoint_id, do: nil, else: parent_id
      checkpoint_map = checkpoint_map(configurable, namespace, checkpoint_id)

      checkpoint =
        checkpoint
        |> stringify_keys()
        |> Map.put_new("id", checkpoint_id)
        |> Map.put_new("ts", DateTime.utc_now() |> DateTime.to_iso8601())
        |> Map.put_new("channel_versions", stringify_keys(new_versions || %{}))

      stored_config =
        %{
          "configurable" => %{
            "thread_id" => thread_id,
            "checkpoint_ns" => namespace,
            "checkpoint_id" => checkpoint_id,
            "checkpoint_map" => checkpoint_map
          }
        }
        |> maybe_put_target_namespace(configurable)

      parent_config =
        if parent_id do
          %{
            "configurable" => %{
              "thread_id" => thread_id,
              "checkpoint_ns" => namespace,
              "checkpoint_id" => parent_id,
              "checkpoint_map" => Map.put(checkpoint_map, namespace, parent_id)
            }
          }
          |> maybe_put_target_namespace(configurable)
        end

      record = %{
        config: stored_config,
        checkpoint: checkpoint,
        metadata: stringify_keys(metadata || %{}),
        parent_config: parent_config
      }

      :ets.insert(saver.checkpoints, {{thread_id, namespace, checkpoint_id}, record})
      {:ok, stored_config}
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
      |> Enum.each(fn {write, index} ->
        {channel, value} = normalize_write(write)

        :ets.insert(
          saver.writes,
          {{thread_id, namespace, checkpoint_id, task_id, index}, {channel, value, task_path}}
        )
      end)

      :ok
    else
      _other -> {:error, {:missing_configurable, "thread_id/checkpoint_id"}}
    end
  end

  @impl true
  def get_delta_channel_history(%__MODULE__{} = saver, config, channel_names, opts) do
    DeltaHistory.get(saver, config, channel_names, opts)
  end

  @impl true
  def delete_thread(%__MODULE__{} = saver, thread_id) do
    for {{^thread_id, namespace, checkpoint_id}, _record} <- :ets.tab2list(saver.checkpoints) do
      :ets.delete(saver.checkpoints, {thread_id, namespace, checkpoint_id})
      delete_writes_for_checkpoint(saver, thread_id, namespace, checkpoint_id)
    end

    :ok
  end

  @impl true
  def delete_for_runs(%__MODULE__{} = saver, run_ids) when is_list(run_ids) do
    run_ids = MapSet.new(run_ids)

    for {{thread_id, namespace, checkpoint_id}, record} <- :ets.tab2list(saver.checkpoints),
        MapSet.member?(run_ids, Map.get(record.metadata, "run_id")) do
      :ets.delete(saver.checkpoints, {thread_id, namespace, checkpoint_id})
      delete_writes_for_checkpoint(saver, thread_id, namespace, checkpoint_id)
    end

    :ok
  end

  @impl true
  def copy_thread(%__MODULE__{} = saver, source_thread_id, target_thread_id) do
    source_records =
      for {{^source_thread_id, namespace, checkpoint_id}, record} <-
            :ets.tab2list(saver.checkpoints) do
        {namespace, checkpoint_id, record}
      end

    Enum.each(source_records, fn {namespace, checkpoint_id, record} ->
      copied = rewrite_thread(record, target_thread_id)
      :ets.insert(saver.checkpoints, {{target_thread_id, namespace, checkpoint_id}, copied})

      for {{^source_thread_id, ^namespace, ^checkpoint_id, task_id, index}, write} <-
            :ets.tab2list(saver.writes) do
        :ets.insert(
          saver.writes,
          {{target_thread_id, namespace, checkpoint_id, task_id, index}, write}
        )
      end
    end)

    :ok
  end

  @impl true
  def prune(%__MODULE__{} = saver, thread_ids, opts) when is_list(thread_ids) do
    strategy = Keyword.get(opts, :strategy, :keep_latest)

    Enum.each(thread_ids, fn thread_id ->
      case strategy do
        :delete ->
          delete_thread(saver, thread_id)

        "delete" ->
          delete_thread(saver, thread_id)

        _keep_latest ->
          keep_latest_by_namespace(saver, thread_id)
      end
    end)

    :ok
  end

  @impl true
  def next_version(_saver, current, _channel), do: Saver.default_next_version(current)

  defp lookup_checkpoint(saver, thread_id, namespace, checkpoint_id) do
    :ets.lookup(saver.checkpoints, {thread_id, namespace, checkpoint_id})
  end

  defp resolve_checkpoint_id(saver, thread_id, namespace, nil) do
    latest = latest_checkpoint_id(saver, thread_id, namespace)

    if latest, do: {:ok, latest}, else: :error
  end

  defp resolve_checkpoint_id(_saver, _thread_id, _namespace, checkpoint_id),
    do: {:ok, checkpoint_id}

  defp latest_checkpoint_id(saver, thread_id, namespace) do
    saver.checkpoints
    |> :ets.tab2list()
    |> Enum.flat_map(fn
      {{^thread_id, ^namespace, checkpoint_id}, _record} -> [checkpoint_id]
      _other -> []
    end)
    |> Enum.sort(:desc)
    |> List.first()
  end

  defp checkpoint_id(%__MODULE__{} = saver, checkpoint) do
    Map.get(checkpoint, "id") || Map.get(checkpoint, :id) || next_checkpoint_id(saver)
  end

  defp next_checkpoint_id(%__MODULE__{} = saver) do
    key = :checkpoint_id

    next =
      case :ets.update_counter(saver.counter, key, {2, 1}, {key, 0}) do
        integer -> integer
      end

    next
    |> Integer.to_string()
    |> String.pad_leading(20, "0")
  end

  defp checkpoint_map(configurable, namespace, checkpoint_id) do
    configurable
    |> Map.get("checkpoint_map", %{})
    |> normalize_checkpoint_map()
    |> Map.put(to_string(namespace || ""), checkpoint_id)
  end

  defp normalize_checkpoint_map(map) when is_map(map) do
    Map.new(map, fn {namespace, id} -> {to_string(namespace || ""), id} end)
  end

  defp normalize_checkpoint_map(_other), do: %{}

  defp maybe_put_target_namespace(config, configurable) do
    case Map.get(configurable, "checkpoint_target_ns") do
      nil -> config
      target -> put_in(config, ["configurable", "checkpoint_target_ns"], target)
    end
  end

  defp put_pending_writes(saver, record) do
    configurable = record.config["configurable"]
    thread_id = configurable["thread_id"]
    namespace = configurable["checkpoint_ns"]
    checkpoint_id = configurable["checkpoint_id"]

    pending_records =
      saver.writes
      |> :ets.tab2list()
      |> Enum.flat_map(fn
        {{^thread_id, ^namespace, ^checkpoint_id, task_id, index}, {channel, value, path}} ->
          [{task_id, index, channel, value, path || ""}]

        _other ->
          []
      end)
      |> Enum.sort_by(fn {task_id, index, _channel, _value, _path} -> {task_id, index} end)

    pending_write_records =
      Enum.map(pending_records, fn {task_id, index, channel, value, path} ->
        %PendingWrite{
          thread_id: thread_id,
          checkpoint_ns: namespace,
          checkpoint_id: checkpoint_id,
          task_id: task_id,
          index: index,
          channel: channel,
          value: value,
          path: path || ""
        }
      end)

    pending_writes = Enum.map(pending_write_records, &PendingWrite.tuple/1)
    pending_write_paths = Enum.map(pending_write_records, &PendingWrite.path_tuple/1)

    record
    |> Map.put(:pending_write_records, pending_write_records)
    |> Map.put(:pending_writes, pending_writes)
    |> Map.put(:pending_write_paths, pending_write_paths)
  end

  defp matches_config?(_record, configurable) when map_size(configurable) == 0, do: true

  defp matches_config?(record, configurable) do
    record_configurable = record.config["configurable"]

    Enum.all?(configurable, fn
      {"thread_id", value} -> record_configurable["thread_id"] == value
      {"checkpoint_ns", value} -> record_configurable["checkpoint_ns"] == value
      {"checkpoint_id", value} -> record_configurable["checkpoint_id"] == value
      {_key, _value} -> true
    end)
  end

  defp matches_filter?(_record, filter) when filter in [nil, %{}], do: true

  defp matches_filter?(record, filter) do
    Enum.all?(filter, fn {key, value} ->
      Map.get(record.metadata, to_string(key)) == value
    end)
  end

  defp before_checkpoint?(_record, nil), do: true
  defp before_checkpoint?(record, before_id), do: record.checkpoint["id"] < before_id

  defp before_checkpoint_id(nil), do: nil

  defp before_checkpoint_id(config) do
    config
    |> Checkpoint.configurable()
    |> Map.get("checkpoint_id")
  end

  defp maybe_take(list, nil), do: list
  defp maybe_take(list, limit) when is_integer(limit), do: Enum.take(list, limit)

  defp normalize_write({channel, value}), do: {to_string(channel), value}
  defp normalize_write({_task_id, channel, value}), do: {to_string(channel), value}

  defp rewrite_thread(record, target_thread_id) do
    rewrite = fn config ->
      put_in(config, ["configurable", "thread_id"], target_thread_id)
    end

    record
    |> Map.update!(:config, rewrite)
    |> Map.update!(:parent_config, fn
      nil -> nil
      parent_config -> rewrite.(parent_config)
    end)
  end

  defp keep_latest_by_namespace(saver, thread_id) do
    grouped =
      saver.checkpoints
      |> :ets.tab2list()
      |> Enum.flat_map(fn
        {{^thread_id, namespace, _checkpoint_id}, record} -> [{namespace, record}]
        _other -> []
      end)
      |> Enum.group_by(fn {namespace, _record} -> namespace end, fn {_ns, record} -> record end)

    Enum.each(grouped, fn {namespace, records} ->
      keep = DeltaCompaction.keep_ids(records)

      Enum.each(records, fn record ->
        checkpoint_id = record.checkpoint["id"]

        unless checkpoint_id in keep do
          :ets.delete(saver.checkpoints, {thread_id, namespace, checkpoint_id})
          delete_writes_for_checkpoint(saver, thread_id, namespace, checkpoint_id)
        end
      end)
    end)
  end

  defp delete_writes_for_checkpoint(saver, thread_id, namespace, checkpoint_id) do
    for {{^thread_id, ^namespace, ^checkpoint_id, task_id, index}, _write} <-
          :ets.tab2list(saver.writes) do
      :ets.delete(saver.writes, {thread_id, namespace, checkpoint_id, task_id, index})
    end
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end
end
