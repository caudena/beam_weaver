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
  alias BeamWeaver.Checkpoint.Ecto.Config
  alias BeamWeaver.Checkpoint.Lineage
  alias BeamWeaver.Checkpoint.PendingWrite
  alias BeamWeaver.Checkpoint.Saver
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Result

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
         id when not is_nil(id) <- checkpoint_id || latest_checkpoint_id(saver, thread_id, namespace),
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
      saver
      |> thread_records(configurable["thread_id"])
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
  defdelegate fork_at(saver, source_config, target_thread_id, opts), to: Lineage

  @impl true
  def put_writes(%__MODULE__{} = saver, config, writes, task_id, task_path) do
    configurable = Checkpoint.configurable(config)

    with thread_id when is_binary(thread_id) <- configurable["thread_id"],
         checkpoint_id when is_binary(checkpoint_id) <- configurable["checkpoint_id"] do
      namespace = Map.get(configurable, "checkpoint_ns", "")

      writes
      |> Enum.with_index()
      |> Enum.each(fn {write, index} ->
        {channel, value} = Config.normalize_write(write)

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
  defdelegate get_delta_channel_history(saver, config, channel_names, opts), to: DeltaHistory, as: :get

  @impl true
  def delete_thread(%__MODULE__{} = saver, thread_id) do
    :ets.match_delete(saver.checkpoints, {{thread_id, :_, :_}, :_})
    :ets.match_delete(saver.writes, {{thread_id, :_, :_, :_, :_}, :_})
    :ok
  end

  @impl true
  def delete_for_runs(%__MODULE__{} = saver, run_ids) when is_list(run_ids) do
    run_ids = MapSet.new(run_ids)

    removed =
      for {key, run_id} <-
            :ets.select(saver.checkpoints, [{{:"$1", %{metadata: %{"run_id" => :"$2"}}}, [], [{{:"$1", :"$2"}}]}]),
          MapSet.member?(run_ids, run_id),
          do: key

    by_thread = Enum.group_by(removed, &elem(&1, 0), &Tuple.delete_at(&1, 0))

    with {:ok, orphans} <- orphans_keeping_history(saver, by_thread) do
      for {thread_id, namespace, checkpoint_id} = key <- removed do
        :ets.delete(saver.checkpoints, key)
        delete_writes_for_checkpoint(saver, thread_id, namespace, checkpoint_id)
      end

      Enum.each(orphans, &clear_parent(saver, &1))
    end
  end

  # The checkpoints left whose parent goes, which become the first of their
  # thread, as after `prune/3`, so their lineage can still be copied. Deleting
  # the runs' checkpoints can't take delta history that one of them reads.
  defp orphans_keeping_history(saver, by_thread) do
    Enum.reduce_while(by_thread, {:ok, []}, fn {thread_id, removed}, {:ok, all} ->
      removed = MapSet.new(removed)

      case saver |> parent_links(thread_id) |> DeltaCompaction.orphans(removed) do
        [] ->
          {:cont, {:ok, all}}

        orphans ->
          if DeltaCompaction.breaks_history?(compaction_records(saver, thread_id), removed),
            do: {:halt, {:error, DeltaCompaction.history_in_use(thread_id)}},
            else: {:cont, {:ok, Enum.map(orphans, fn {namespace, id} -> {thread_id, namespace, id} end) ++ all}}
      end
    end)
  end

  # A thread's checkpoints as `DeltaCompaction` records of only their id and
  # parent, read without copying the checkpoints.
  defp parent_links(saver, thread_id) do
    linked = [
      {{{thread_id, :"$1", :"$2"}, %{parent_config: %{"configurable" => %{"checkpoint_id" => :"$3"}}}}, [],
       [{{:"$1", :"$2", :"$3"}}]}
    ]

    saver.checkpoints
    |> :ets.select(linked)
    |> Enum.group_by(&elem(&1, 0), fn {_namespace, id, parent_id} -> %{id: id, parent_id: parent_id} end)
  end

  defp clear_parent(saver, key) do
    case :ets.lookup(saver.checkpoints, key) do
      [{^key, record}] -> :ets.insert(saver.checkpoints, {key, %{record | parent_config: nil}})
      [] -> true
    end
  end

  @impl true
  def copy_thread(%__MODULE__{} = saver, source_thread_id, target_thread_id) do
    source_records =
      for {{_thread, namespace, checkpoint_id}, record} <-
            :ets.match_object(saver.checkpoints, {{source_thread_id, :_, :_}, :_}) do
        {namespace, checkpoint_id, record}
      end

    Enum.each(source_records, fn {namespace, checkpoint_id, record} ->
      copied = rewrite_thread(record, target_thread_id)
      :ets.insert(saver.checkpoints, {{target_thread_id, namespace, checkpoint_id}, copied})

      for {{_thread, _namespace, _checkpoint_id, task_id, index}, write} <-
            :ets.match_object(saver.writes, {{source_thread_id, namespace, checkpoint_id, :_, :_}, :_}) do
        :ets.insert(
          saver.writes,
          {{target_thread_id, namespace, checkpoint_id, task_id, index}, write}
        )
      end
    end)

    source_records
    |> Enum.group_by(&elem(&1, 0), fn {_namespace, _id, record} -> record.commit_order end)
    |> Enum.each(fn {namespace, orders} ->
      :ets.insert(saver.counter, {{:commit_order, target_thread_id, namespace}, Enum.max(orders)})
    end)

    :ok
  end

  @impl true
  def prune(%__MODULE__{} = saver, thread_ids, opts) when is_list(thread_ids) do
    with {:ok, strategy} <- DeltaCompaction.strategy(opts) do
      Enum.each(thread_ids, fn thread_id ->
        if strategy == :delete,
          do: delete_thread(saver, thread_id),
          else: keep_latest_by_namespace(saver, thread_id)
      end)
    end
  end

  @impl true
  def next_version(_saver, current, _channel), do: Saver.default_next_version(current)

  defp lookup_checkpoint(saver, thread_id, namespace, checkpoint_id) do
    :ets.lookup(saver.checkpoints, {thread_id, namespace, checkpoint_id})
  end

  defp latest_checkpoint_id(saver, thread_id, namespace) do
    saver
    |> commit_orders(thread_id, namespace)
    |> Enum.max_by(&elem(&1, 0), fn -> {nil, nil} end)
    |> elem(1)
  end

  # The commit order and id of each checkpoint of the thread, read without
  # copying the checkpoints out of the table.
  defp commit_orders(saver, thread_id, namespace) when is_binary(thread_id) and is_binary(namespace) do
    :ets.select(saver.checkpoints, [{{{thread_id, namespace, :"$1"}, %{commit_order: :"$2"}}, [], [{{:"$2", :"$1"}}]}])
  end

  defp commit_orders(saver, thread_id, namespace) do
    for {{_thread, _namespace, checkpoint_id}, record} <-
          :ets.match_object(saver.checkpoints, {{thread_id, namespace, :_}, :_}),
        do: {record.commit_order, checkpoint_id}
  end

  defp checkpoint_id(%__MODULE__{} = saver, checkpoint) do
    Map.get(checkpoint, "id") || Map.get(checkpoint, :id) || next_checkpoint_id(saver)
  end

  defp next_checkpoint_id(%__MODULE__{} = saver) do
    saver.counter
    |> :ets.update_counter(:checkpoint_id, {2, 1}, {:checkpoint_id, 0})
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

  defp put_pending_writes(saver, record) when is_map(record),
    do: saver |> put_pending_writes([record]) |> List.first()

  defp put_pending_writes(saver, records) when is_list(records) do
    parents = Map.new(records, &{checkpoint_key(&1), stored_parent_key(saver, &1)})

    keys = MapSet.new(Map.keys(parents) ++ for({_key, parent_key} <- parents, parent_key, do: parent_key))

    writes =
      for {{thread, namespace, checkpoint, task, index}, {channel, value, path}} <- checkpoint_writes(saver, keys),
          MapSet.member?(keys, {thread, namespace, checkpoint}) do
        %PendingWrite{
          thread_id: thread,
          checkpoint_ns: namespace,
          checkpoint_id: checkpoint,
          task_id: task,
          index: index,
          channel: channel,
          value: value,
          path: path || ""
        }
      end

    pending = Enum.group_by(writes, &{&1.thread_id, &1.checkpoint_ns, &1.checkpoint_id})

    Enum.map(records, fn record ->
      key = checkpoint_key(record)
      writes = sorted_writes(pending, key)

      record
      |> Map.put(:pending_write_records, writes)
      |> Map.put(:pending_writes, Enum.map(writes, &PendingWrite.tuple/1))
      |> Map.put(:pending_write_paths, Enum.map(writes, &PendingWrite.path_tuple/1))
      |> put_parent_pending_writes(Map.fetch!(parents, key), pending)
    end)
  end

  defp sorted_writes(pending, key), do: pending |> Map.get(key, []) |> Enum.sort_by(&{&1.task_id, &1.index})

  # Reading a tuple needs its parent's pending writes. They come with the
  # tuple, so the parent checkpoint isn't read as well.
  defp put_parent_pending_writes(record, nil, _pending), do: record

  defp put_parent_pending_writes(record, parent_key, pending) do
    writes = pending |> sorted_writes(parent_key) |> Enum.map(&PendingWrite.tuple/1)
    Map.put(record, :parent_pending_writes, writes)
  end

  defp stored_parent_key(saver, %{parent_config: parent_config}) when is_map(parent_config) do
    configurable = Checkpoint.configurable(parent_config)
    key = {configurable["thread_id"], Map.get(configurable, "checkpoint_ns", ""), configurable["checkpoint_id"]}

    if binary_key?(key) and :ets.member(saver.checkpoints, key), do: key
  end

  defp stored_parent_key(_saver, _record), do: nil

  defp binary_key?({thread, namespace, checkpoint}),
    do: is_binary(thread) and is_binary(namespace) and is_binary(checkpoint)

  # The checkpoints of a thread are the keys that start with its id, so they
  # are read without going through the other threads' checkpoints.
  defp thread_records(saver, thread_id) when is_binary(thread_id) do
    for {_key, record} <- :ets.match_object(saver.checkpoints, {{thread_id, :_, :_}, :_}), do: record
  end

  defp thread_records(saver, _thread_id) do
    for {_key, record} <- :ets.tab2list(saver.checkpoints), do: record
  end

  # The pending writes of the given checkpoints, read by key prefix, or by
  # copying the table when it holds no more writes than there are checkpoints
  # to look up.
  defp checkpoint_writes(saver, keys) do
    if Enum.all?(keys, &binary_key?/1) and :ets.info(saver.writes, :size) > MapSet.size(keys) do
      Enum.flat_map(keys, fn {thread, namespace, checkpoint} ->
        :ets.match_object(saver.writes, {{thread, namespace, checkpoint, :_, :_}, :_})
      end)
    else
      :ets.tab2list(saver.writes)
    end
  end

  defp checkpoint_key(record) do
    configurable = record.config["configurable"]

    {
      configurable["thread_id"],
      configurable["checkpoint_ns"],
      configurable["checkpoint_id"]
    }
  end

  defp matches_config?(record, configurable) do
    Enum.all?(configurable, fn {key, value} ->
      key not in ["thread_id", "checkpoint_ns", "checkpoint_id"] or record.config["configurable"][key] == value
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

  # The plan comes from one read of the thread, so a checkpoint saved while
  # the thread is pruned stays.
  defp keep_latest_by_namespace(saver, thread_id) do
    {removals, roots} = saver |> compaction_records(thread_id) |> DeltaCompaction.prune_plan()

    for {namespace, checkpoint_id} <- removals do
      :ets.delete(saver.checkpoints, {thread_id, namespace, checkpoint_id})
      delete_writes_for_checkpoint(saver, thread_id, namespace, checkpoint_id)
    end

    Enum.each(roots, fn {namespace, checkpoint_id} -> clear_parent(saver, {thread_id, namespace, checkpoint_id}) end)
  end

  defp compaction_records(saver, thread_id) do
    pending =
      saver.writes
      |> :ets.select([{{{thread_id, :"$1", :"$2", :_, :_}, {:"$3", :_, :_}}, [], [{{:"$1", :"$2", :"$3"}}]}])
      |> Enum.group_by(fn {namespace, checkpoint_id, _channel} -> {namespace, checkpoint_id} end, &elem(&1, 2))

    saver.checkpoints
    |> :ets.match_object({{thread_id, :_, :_}, :_})
    |> Enum.group_by(
      fn {{_thread, namespace, _id}, _record} -> namespace end,
      fn {{_thread, namespace, checkpoint_id}, record} ->
        %{
          id: checkpoint_id,
          parent_id: parent_id(record),
          commit_order: record.commit_order,
          checkpoint: record.checkpoint,
          metadata: record.metadata,
          pending_channels: pending |> Map.get({namespace, checkpoint_id}, []) |> MapSet.new(),
          root_id: get_in(record.config, ["configurable", "checkpoint_map", ""])
        }
      end
    )
  end

  defp parent_id(%{parent_config: %{"configurable" => configurable}}), do: configurable["checkpoint_id"]
  defp parent_id(_record), do: nil

  defp delete_writes_for_checkpoint(saver, thread_id, namespace, checkpoint_id),
    do: :ets.match_delete(saver.writes, {{thread_id, namespace, checkpoint_id, :_, :_}, :_})

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
      checkpoint_map = Config.checkpoint_map(configurable, namespace, checkpoint_id)
      key = {thread_id, namespace, checkpoint_id}

      stored_config =
        Config.stored_config(thread_id, namespace, checkpoint_id, checkpoint_map, configurable["checkpoint_target_ns"])

      # A checkpoint saved again keeps its place in the thread: its commit
      # order and its parent.
      {order, parent_config} =
        case :ets.lookup(saver.checkpoints, key) do
          [{^key, record}] ->
            {record.commit_order, record.parent_config}

          [] ->
            parent_config = parent_id && put_in(stored_config, ["configurable", "checkpoint_id"], parent_id)
            {next_commit_order(saver, thread_id, namespace), parent_config}
        end

      record = %{
        config: stored_config,
        checkpoint:
          checkpoint
          |> Config.stringify_keys()
          |> Map.put_new("id", checkpoint_id)
          |> Map.put_new("ts", DateTime.utc_now() |> DateTime.to_iso8601())
          |> Map.put_new("channel_versions", Config.stringify_keys(versions || %{})),
        metadata: Config.stringify_keys(metadata || %{}),
        parent_config: parent_config,
        commit_order: order
      }

      {:ok, key, record}
    else
      {:error, Error.new(:invalid_checkpoint, "checkpoint config requires thread_id")}
    end
  end

  defp prepare_batch(saver, entries) do
    Enum.reduce_while(entries, {:ok, [], %{}}, fn entry, {:ok, prepared, heads} ->
      {:ok, config, checkpoint, metadata, versions, writes, write_opts} = Batch.entry(entry)
      configurable = Checkpoint.configurable(config)
      owner = {configurable["thread_id"], Map.get(configurable, "checkpoint_ns", "")}
      parent_id = configurable["checkpoint_id"] || Map.get(heads, owner) || :latest

      with {:ok, key, record} <- prepare_record(saver, config, checkpoint, metadata, versions, parent_id),
           {:ok, write_objects} <- batch_writes(key, writes, write_opts) do
        next = %{key: key, record: record, writes: write_objects}
        {:cont, {:ok, [next | prepared], Map.put(heads, owner, elem(key, 2))}}
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
    |> Result.traverse(fn {write, index} ->
      case Batch.write(write, default_task, default_path) do
        {:ok, task_id, write_index, channel, value, path} ->
          {:ok, {{thread_id, namespace, checkpoint_id, task_id, write_index || index}, {channel, value, path}}}

        :error ->
          {:error, Error.new(:invalid_checkpoint_batch, "invalid pending write")}
      end
    end)
  end

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
