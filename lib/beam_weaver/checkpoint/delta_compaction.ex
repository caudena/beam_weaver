defmodule BeamWeaver.Checkpoint.DeltaCompaction do
  @moduledoc false

  # Which checkpoints of a thread `prune` keeps and `delete_for_runs` may
  # delete. A saver describes each checkpoint of the thread as a record:
  #
  #   * `:id`, `:parent_id`, `:commit_order`
  #   * `:checkpoint` and `:metadata`, decoded
  #   * `:pending_channels` - the channels of the pending writes saved on it
  #   * `:root_id` - the id of the top-level checkpoint a subgraph's
  #     checkpoint belongs to (its `checkpoint_map[""]`), or nil
  #
  # and groups the records by namespace.

  alias BeamWeaver.Checkpoint.DeltaHistory
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Graph.Channels.DeltaSnapshot
  alias BeamWeaver.MapAccess

  @spec strategy(keyword()) :: {:ok, :keep_latest | :delete} | {:error, Error.t()}
  def strategy(opts) do
    case Keyword.get(opts, :strategy, :keep_latest) do
      strategy when strategy in [:keep_latest, "keep_latest"] ->
        {:ok, :keep_latest}

      strategy when strategy in [:delete, "delete"] ->
        {:ok, :delete}

      strategy ->
        {:error,
         Error.new(:invalid_prune_strategy, "prune strategy must be :keep_latest or :delete", %{
           strategy: inspect(strategy)
         })}
    end
  end

  # What `keep_latest` does to a thread: the `{namespace, id}` checkpoints it
  # deletes, and the kept ones whose parent goes, which become the first of
  # their thread so their lineage can still be copied. It keeps in each
  # namespace the latest checkpoint and the ones before it that its delta
  # channels still read. A subgraph call's namespace whose top-level
  # checkpoint goes is dropped whole: the call is over.
  @spec prune_plan(%{String.t() => [map()]}) :: {[{String.t(), String.t()}], [{String.t(), String.t()}]}
  def prune_plan(namespaces) do
    root_kept = namespaces |> Map.get("", []) |> keep_ids()

    for {namespace, records} <- namespaces,
        kept = if(finished_call?(namespace, records, root_kept), do: MapSet.new(), else: keep_ids(records)),
        record <- records,
        reduce: {[], []} do
      {removals, roots} ->
        cond do
          not MapSet.member?(kept, record.id) -> {[{namespace, record.id} | removals], roots}
          record.parent_id && not MapSet.member?(kept, record.parent_id) -> {removals, [{namespace, record.id} | roots]}
          true -> {removals, roots}
        end
    end
  end

  # The `{namespace, id}` checkpoints that stay when the ones in `removed`
  # are deleted but whose parent is deleted. A record needs only `:id` and
  # `:parent_id` here.
  @spec orphans(%{String.t() => [map()]}, MapSet.t()) :: [{String.t(), String.t()}]
  def orphans(namespaces, removed) do
    for {namespace, records} <- namespaces,
        record <- records,
        orphan?(record, namespace, removed),
        do: {namespace, record.id}
  end

  # Whether deleting the `{namespace, id}` checkpoints in `removed` takes
  # delta history that a remaining checkpoint reads. Only an orphan can lose
  # some: any other remaining checkpoint reads the deleted ones through it.
  @spec breaks_history?(%{String.t() => [map()]}, MapSet.t()) :: boolean()
  def breaks_history?(namespaces, removed) do
    Enum.any?(namespaces, fn {namespace, records} ->
      by_id = Map.new(records, &{&1.id, &1})

      records
      |> Enum.filter(&orphan?(&1, namespace, removed))
      |> Enum.any?(fn record -> record |> history(by_id) |> Enum.any?(&MapSet.member?(removed, {namespace, &1.id})) end)
    end)
  end

  @spec history_in_use(String.t()) :: Error.t()
  def history_in_use(thread_id) do
    Error.new(
      :delta_history_in_use,
      "later checkpoints of the thread read delta channel history that the runs' checkpoints hold",
      %{thread_id: thread_id}
    )
  end

  defp orphan?(record, namespace, removed),
    do: not MapSet.member?(removed, {namespace, record.id}) and MapSet.member?(removed, {namespace, record.parent_id})

  defp keep_ids([]), do: MapSet.new()

  defp keep_ids(records) do
    by_id = Map.new(records, &{&1.id, &1})

    records
    |> Enum.max_by(& &1.commit_order)
    |> history(by_id)
    |> MapSet.new(& &1.id)
  end

  # The checkpoints from `head` back through its parents, newest first, as
  # far as its delta channels read: for each, back to the nearest checkpoint
  # that stores its value, or else to the oldest that holds a write to it.
  defp history(head, by_id) do
    chain = chain(head, by_id, MapSet.new())
    length = chain |> delta_channels() |> Enum.map(&read_length(chain, &1)) |> Enum.max(fn -> 1 end)
    Enum.take(chain, length)
  end

  defp chain(nil, _by_id, _seen), do: []

  defp chain(record, by_id, seen) do
    if MapSet.member?(seen, record.id),
      do: [],
      else: [record | chain(Map.get(by_id, record.parent_id), by_id, MapSet.put(seen, record.id))]
  end

  defp read_length(chain, channel) do
    chain
    |> Enum.with_index(1)
    |> Enum.reduce_while(1, fn {record, length}, read ->
      cond do
        stores?(record, channel) -> {:halt, length}
        writes?(record, channel) -> {:cont, length}
        true -> {:cont, read}
      end
    end)
  end

  # The delta channels of a chain: those its graph counted towards a
  # snapshot, wrote as deltas or stored a snapshot of.
  defp delta_channels(chain) do
    chain
    |> Enum.flat_map(fn record ->
      counters = MapAccess.get(record.metadata, "counters_since_delta_snapshot", %{})

      snapshots =
        for {channel, value} <- Map.get(record.checkpoint, "channel_values", %{}),
            DeltaSnapshot.snapshot?(value),
            do: channel

      map_keys(counters) ++ map_keys(Map.get(record.checkpoint, "channel_deltas", %{})) ++ snapshots
    end)
    |> MapSet.new(&to_string/1)
  end

  defp stores?(record, channel), do: match?({:ok, _value}, DeltaHistory.stored_value(record, channel))

  defp writes?(record, channel) do
    deltas = Map.get(record.checkpoint, "channel_deltas", %{})
    MapSet.member?(record.pending_channels, channel) or MapAccess.get(deltas, channel, []) != []
  end

  defp finished_call?(namespace, records, root_kept) do
    task_namespace?(namespace) and
      case Enum.max_by(records, & &1.commit_order, fn -> nil end) do
        %{root_id: root_id} when is_binary(root_id) -> not MapSet.member?(root_kept, root_id)
        _other -> false
      end
  end

  # A subgraph namespace that holds one call: a task's id follows its node's
  # name in one of its segments.
  defp task_namespace?(namespace), do: namespace != "" and String.contains?(namespace, ":")

  defp map_keys(map) when is_map(map), do: Map.keys(map)
  defp map_keys(_value), do: []
end
