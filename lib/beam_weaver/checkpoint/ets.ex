defmodule BeamWeaver.Checkpoint.ETS do
  @moduledoc """
  ETS implementation of `BeamWeaver.Checkpoint.Saver`.

  This adapter is intended for tests, local workflows, and lightweight
  supervised deployments. It uses the same saver contract as the Ecto/Postgres
  adapter, so graph and agent code never branch on storage backend.
  """

  @behaviour BeamWeaver.Checkpoint.Saver

  alias BeamWeaver.Checkpoint
  alias BeamWeaver.Checkpoint.Batch
  alias BeamWeaver.Checkpoint.DeltaCompaction
  alias BeamWeaver.Checkpoint.DeltaHistory
  alias BeamWeaver.Checkpoint.Lineage
  alias BeamWeaver.Checkpoint.PendingWrite
  alias BeamWeaver.Checkpoint.Saver
  alias BeamWeaver.Core.Error

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
    before_order = before_commit_order(saver, before_config)

    records =
      saver.checkpoints
      |> :ets.tab2list()
      |> Enum.map(fn {_key, record} -> record end)
      |> Enum.filter(
        &(matches_config?(&1, configurable) and matches_filter?(&1, filter) and
            before_checkpoint?(&1, before_order))
      )
      |> Enum.sort_by(& &1.commit_order, :desc)
      |> maybe_take(limit)

    put_pending_writes(saver, records)
  end

  @impl true
  def put(%__MODULE__{} = saver, config, checkpoint, metadata, new_versions) do
    with {:ok, key, record} <- prepare_record(saver, config, checkpoint, metadata, new_versions) do
      :ets.insert(saver.checkpoints, {key, record})
      {:ok, record.config}
    end
  end

  @impl true
  def put_many(%__MODULE__{} = saver, entries, _opts) do
    with :ok <- Batch.validate(entries),
         {:ok, prepared} <- prepare_batch(saver, entries),
         :ok <- ensure_new_keys(saver, prepared) do
      write_objects = Enum.flat_map(prepared, & &1.writes)
      checkpoint_objects = Enum.map(prepared, &{&1.key, &1.record})

      :ets.insert(saver.writes, write_objects)
      true = :ets.insert_new(saver.checkpoints, checkpoint_objects)

      {:ok, Enum.map(prepared, & &1.record.config)}
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

    source_records
    |> Enum.group_by(fn {namespace, _checkpoint_id, _record} -> namespace end)
    |> Enum.each(fn {namespace, records} ->
      highest = records |> Enum.map(fn {_namespace, _id, record} -> record.commit_order end) |> Enum.max()
      :ets.insert(saver.counter, {{:commit_order, target_thread_id, namespace}, highest})
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
      {{^thread_id, ^namespace, checkpoint_id}, record} -> [{record.commit_order, checkpoint_id}]
      _other -> []
    end)
    |> Enum.max_by(&elem(&1, 0), fn -> nil end)
    |> case do
      nil -> nil
      {_order, checkpoint_id} -> checkpoint_id
    end
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

  defp next_commit_order(%__MODULE__{} = saver, thread_id, namespace) do
    :ets.update_counter(
      saver.counter,
      {:commit_order, thread_id, namespace},
      {2, 1},
      {{:commit_order, thread_id, namespace}, 0}
    )
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

  defp put_pending_writes(saver, record) when is_map(record),
    do: saver |> put_pending_writes([record]) |> List.first()

  defp put_pending_writes(saver, records) when is_list(records) do
    keys = MapSet.new(records, &checkpoint_key/1)

    pending =
      saver.writes
      |> :ets.tab2list()
      |> Enum.reduce(%{}, fn
        {{thread, namespace, checkpoint, task, index}, {channel, value, path}}, acc ->
          key = {thread, namespace, checkpoint}

          if MapSet.member?(keys, key) do
            write = %PendingWrite{
              thread_id: thread,
              checkpoint_ns: namespace,
              checkpoint_id: checkpoint,
              task_id: task,
              index: index,
              channel: channel,
              value: value,
              path: path || ""
            }

            Map.update(acc, key, [write], &[write | &1])
          else
            acc
          end
      end)

    Enum.map(records, fn record ->
      writes =
        pending
        |> Map.get(checkpoint_key(record), [])
        |> Enum.sort_by(&{&1.task_id, &1.index})

      record
      |> Map.put(:pending_write_records, writes)
      |> Map.put(:pending_writes, Enum.map(writes, &PendingWrite.tuple/1))
      |> Map.put(:pending_write_paths, Enum.map(writes, &PendingWrite.path_tuple/1))
    end)
  end

  defp checkpoint_key(record) do
    configurable = record.config["configurable"]

    {
      configurable["thread_id"],
      configurable["checkpoint_ns"],
      configurable["checkpoint_id"]
    }
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
  defp before_checkpoint?(record, before_order), do: record.commit_order < before_order

  defp before_commit_order(_saver, nil), do: nil

  defp before_commit_order(saver, config) do
    configurable = Checkpoint.configurable(config)

    case lookup_checkpoint(
           saver,
           configurable["thread_id"],
           Map.get(configurable, "checkpoint_ns", ""),
           configurable["checkpoint_id"]
         ) do
      [{_key, record}] -> record.commit_order
      _other -> nil
    end
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

  defp prepare_record(saver, config, checkpoint, metadata, versions, parent_id \\ :latest) do
    configurable = Checkpoint.configurable(config)
    thread_id = configurable["thread_id"]
    namespace = to_string(Map.get(configurable, "checkpoint_ns", "") || "")

    if is_binary(thread_id) and thread_id != "" and is_map(checkpoint) do
      checkpoint_id = checkpoint_id(saver, checkpoint)

      parent_id =
        case parent_id do
          :latest -> configurable["checkpoint_id"] || latest_checkpoint_id(saver, thread_id, namespace)
          explicit -> explicit
        end

      parent_id = if parent_id == checkpoint_id, do: nil, else: parent_id
      checkpoint_map = checkpoint_map(configurable, namespace, checkpoint_id)
      key = {thread_id, namespace, checkpoint_id}

      order =
        case :ets.lookup(saver.checkpoints, key) do
          [{^key, record}] -> record.commit_order
          [] -> next_commit_order(saver, thread_id, namespace)
        end

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

      record = %{
        config: stored_config,
        checkpoint:
          checkpoint
          |> stringify_keys()
          |> Map.put_new("id", checkpoint_id)
          |> Map.put_new("ts", DateTime.utc_now() |> DateTime.to_iso8601())
          |> Map.put_new("channel_versions", stringify_keys(versions || %{})),
        metadata: stringify_keys(metadata || %{}),
        parent_config: parent_config(stored_config, parent_id),
        commit_order: order
      }

      {:ok, key, record}
    else
      {:error, Error.new(:invalid_checkpoint, "checkpoint config requires thread_id")}
    end
  end

  defp parent_config(_config, nil), do: nil

  defp parent_config(config, parent_id) do
    put_in(config, ["configurable", "checkpoint_id"], parent_id)
  end

  defp prepare_batch(saver, entries) do
    Enum.reduce_while(entries, {:ok, [], %{}}, fn entry, {:ok, prepared, heads} ->
      with {:ok, config, checkpoint, metadata, versions, writes, write_opts} <- Batch.entry(entry) do
        configurable = Checkpoint.configurable(config)
        owner = {configurable["thread_id"], Map.get(configurable, "checkpoint_ns", "")}
        parent_id = configurable["checkpoint_id"] || Map.get(heads, owner) || :latest

        with {:ok, key, record} <-
               prepare_record(saver, config, checkpoint, metadata, versions, parent_id),
             {:ok, write_objects} <- batch_writes(key, writes, write_opts) do
          next = %{key: key, record: record, writes: write_objects}
          checkpoint_id = elem(key, 2)
          {:cont, {:ok, [next | prepared], Map.put(heads, owner, checkpoint_id)}}
        else
          {:error, %Error{}} = error -> {:halt, error}
        end
      else
        {:error, %Error{}} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, prepared, _heads} -> {:ok, Enum.reverse(prepared)}
      {:error, %Error{}} = error -> error
    end
  end

  defp batch_writes({thread_id, namespace, checkpoint_id}, writes, opts) do
    default_task = Keyword.get(opts, :task_id, "checkpoint")
    default_path = Keyword.get(opts, :task_path, "")

    writes
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {write, index}, {:ok, objects} ->
      case normalize_batch_write(write, default_task, default_path) do
        {:ok, task_id, write_index, channel, value, path} ->
          object =
            {{thread_id, namespace, checkpoint_id, task_id, write_index || index}, {channel, value, path}}

          {:cont, {:ok, [object | objects]}}

        :error ->
          {:halt, {:error, Error.new(:invalid_checkpoint_batch, "invalid pending write")}}
      end
    end)
    |> case do
      {:ok, objects} -> {:ok, Enum.reverse(objects)}
      {:error, %Error{}} = error -> error
    end
  end

  defp normalize_batch_write(%PendingWrite{} = write, _task, _path),
    do: {:ok, write.task_id, write.index, to_string(write.channel), write.value, write.path || ""}

  defp normalize_batch_write({task, channel, value, path}, _default_task, _default_path)
       when is_binary(task),
       do: {:ok, task, nil, to_string(channel), value, to_string(path || "")}

  defp normalize_batch_write({task, channel, value}, _default_task, default_path)
       when is_binary(task),
       do: {:ok, task, nil, to_string(channel), value, to_string(default_path || "")}

  defp normalize_batch_write({channel, value}, task, path),
    do: {:ok, task, nil, to_string(channel), value, to_string(path || "")}

  defp normalize_batch_write(_write, _task, _path), do: :error

  defp ensure_new_keys(saver, prepared) do
    keys = Enum.map(prepared, & &1.key)

    cond do
      length(keys) != length(Enum.uniq(keys)) ->
        {:error, Error.new(:checkpoint_conflict, "checkpoint batch contains duplicate identities")}

      Enum.any?(keys, &(:ets.lookup(saver.checkpoints, &1) != [])) ->
        {:error, Error.new(:checkpoint_conflict, "checkpoint identity already exists")}

      true ->
        :ok
    end
  end
end
