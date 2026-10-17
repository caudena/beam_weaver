defmodule BeamWeaver.Graph.Execution.DeltaReplay do
  @moduledoc false

  alias BeamWeaver.Checkpoint
  alias BeamWeaver.Checkpoint.DeltaHistory
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Graph.Channel
  alias BeamWeaver.Graph.Channels.DeltaChannel
  alias BeamWeaver.Graph.Execution
  alias BeamWeaver.Graph.Execution.ChannelLookup
  alias BeamWeaver.Graph.StateGraph
  alias BeamWeaver.MapAccess

  # Restores the values a checkpoint doesn't store in full from the thread's
  # history: every delta channel's, and the value of a key that a delta
  # channel held before the graph changed it to another channel, until a
  # checkpoint stores that key's value. A delta channel never written has
  # its initial value, without reading the history. A stored delta snapshot
  # reads as its value whatever the key's channel is now.
  @spec restore_channel_values(map(), map(), map()) :: {:ok, map()} | {:error, Error.t()}
  def restore_channel_values(%{graph: %StateGraph{channels: channels}} = compiled, tuple, values) do
    restored = Map.get_lazy(tuple, :delta_values, fn -> read_history(compiled, tuple, values) end)

    Enum.reduce_while(channels, {:ok, values}, fn {key, channel}, {:ok, values} ->
      case restored_value(channel, Map.fetch(restored, to_string(key)), DeltaHistory.stored_in(values, key)) do
        {:ok, value} -> {:cont, {:ok, Map.put(values, key, value)}}
        :missing -> {:cont, {:ok, values |> Map.delete(key) |> Map.delete(to_string(key))}}
        {:error, %Error{}} = error -> {:halt, error}
      end
    end)
  end

  # The tuples of a history, newest first, each with what
  # `restore_channel_values/3` restores for it. A checkpoint whose parent the
  # history holds starts from the parent's values, so the history's
  # checkpoints don't each read their ancestors.
  @spec put_history_values(map(), [map()]) :: [map()]
  def put_history_values(%{graph: %StateGraph{}} = compiled, tuples) do
    tuples
    |> Enum.reverse()
    |> Enum.map_reduce(%{}, fn tuple, known ->
      restored = history_values(compiled, tuple, Map.get(known, parent_key(tuple)))
      {Map.put(tuple, :delta_values, restored), Map.put(known, checkpoint_key(tuple), {tuple, restored})}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp restored_value(_channel, {:ok, result}, _stored), do: result

  defp restored_value(%DeltaChannel{} = channel, :error, _stored),
    do: channel_value(Channel.from_checkpoint(channel, Channel.missing()))

  defp restored_value(_channel, :error, {:ok, value}), do: {:ok, value}
  defp restored_value(_channel, :error, :error), do: :missing

  defp read_history(compiled, tuple, values) do
    case replayed_keys(compiled.graph, tuple, values) do
      [] -> %{}
      keys -> walk_history(compiled, tuple, keys)
    end
  end

  defp walk_history(%{checkpointer: nil}, _tuple, _keys), do: %{}

  defp walk_history(compiled, tuple, keys) do
    compiled.checkpointer
    |> Checkpoint.get_delta_channel_history(tuple.config, keys)
    |> Map.new(fn {key, history} -> {key, replay(channel(compiled.graph, key), history)} end)
  end

  defp history_values(compiled, tuple, parent) do
    case {replayed_keys(compiled.graph, tuple, Execution.checkpoint_values(tuple.checkpoint)), parent} do
      {[], _parent} ->
        %{}

      {keys, {parent_tuple, parent_restored}} ->
        Map.new(keys, &{&1, from_parent(compiled, tuple, &1, parent_tuple, parent_restored)})

      {keys, nil} ->
        walk_history(compiled, tuple, keys)
    end
  end

  # A key's value at a checkpoint, from the value its parent restored or
  # stored: the parent's pending writes, then the checkpoint's own step. A key
  # whose value the parent couldn't restore fails the same way, unless the
  # checkpoint stores it.
  defp from_parent(compiled, tuple, key, parent_tuple, parent_restored) do
    case {DeltaHistory.stored_value(tuple, key), Map.get(parent_restored, key)} do
      {{:ok, seed}, _parent} ->
        replay(channel(compiled.graph, key), %{seed: seed, writes: []})

      {:error, {:error, %Error{}} = error} ->
        error

      {:error, parent} ->
        replay(channel(compiled.graph, key), %{
          seed: parent_value(parent_tuple, key, parent),
          writes: DeltaHistory.pending_writes(parent_tuple, key) ++ DeltaHistory.step_writes(tuple, key)
        })
    end
  end

  defp parent_value(_tuple, _key, {:ok, value}), do: value
  defp parent_value(_tuple, _key, :missing), do: Channel.missing()

  defp parent_value(tuple, key, nil) do
    case DeltaHistory.stored_value(tuple, key) do
      {:ok, value} -> value
      :error -> Channel.missing()
    end
  end

  # The keys a checkpoint restores from history: the delta channels written
  # by then (they have a version), and the keys with no stored value that a
  # delta channel wrote, which the checkpoint's snapshot counters or step
  # writes name.
  defp replayed_keys(%StateGraph{channels: channels}, tuple, values) do
    checkpoint = tuple.checkpoint
    versions = Map.get(checkpoint, "channel_versions", %{})
    deltas = Map.get(checkpoint, "channel_deltas", %{})
    counters = MapAccess.get(tuple.metadata || %{}, "counters_since_delta_snapshot", %{})

    for {key, channel} <- channels,
        name = to_string(key),
        replayed_key?(channel, name, values, versions, deltas, counters),
        do: name
  end

  defp replayed_key?(%DeltaChannel{}, name, values, versions, deltas, _counters),
    do: Enum.any?([versions, deltas, values], &MapAccess.has_key?(&1, name))

  defp replayed_key?(_channel, name, values, _versions, deltas, counters),
    do:
      DeltaHistory.stored_in(values, name) == :error and
        (MapAccess.has_key?(counters, name) or Map.has_key?(deltas, name))

  # A channel's value after its history: the seed with the writes applied,
  # the writes of one step at a time, as they were made.
  defp replay(%DeltaChannel{} = channel, history) do
    {:ok, replayed, _changed?} =
      channel
      |> Channel.from_checkpoint(history.seed)
      |> DeltaChannel.replay_writes(history.writes)

    channel_value(replayed)
  end

  defp replay(channel, history) do
    history.writes
    |> DeltaChannel.steps()
    |> Enum.reduce_while({:ok, Channel.from_checkpoint(channel, history.seed)}, fn writes, {:ok, channel} ->
      case Channel.update(channel, writes) do
        {:ok, channel, _changed?} -> {:cont, {:ok, channel}}
        {:error, %Error{}} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, channel} -> channel_value(channel)
      {:error, %Error{}} = error -> error
    end
  end

  defp channel_value(channel) do
    case Channel.get(channel) do
      {:ok, value} -> {:ok, value}
      {:error, %Error{type: :empty_channel}} -> :missing
      {:error, %Error{}} = error -> error
    end
  end

  defp channel(graph, name), do: ChannelLookup.channel_for(graph, name)

  defp checkpoint_key(tuple) do
    configurable = tuple.config["configurable"]
    {configurable["checkpoint_ns"], configurable["checkpoint_id"]}
  end

  defp parent_key(%{parent_config: %{"configurable" => configurable}}),
    do: {configurable["checkpoint_ns"], configurable["checkpoint_id"]}

  defp parent_key(_tuple), do: nil
end
