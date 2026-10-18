defmodule BeamWeaver.Graph.Execution.ChannelCheckpoint do
  @moduledoc false

  alias BeamWeaver.Graph.Channel
  alias BeamWeaver.Graph.Channels.DeltaChannel
  alias BeamWeaver.Graph.Channels.DeltaSnapshot
  alias BeamWeaver.Graph.Execution.ChannelLookup
  alias BeamWeaver.Graph.Execution.ChannelMerge
  alias BeamWeaver.Graph.StateGraph

  @spec checkpoint_channel_values(StateGraph.t(), map()) :: map()
  def checkpoint_channel_values(%StateGraph{} = graph, state) do
    for {key, value} <- state, ChannelLookup.checkpointed_channel?(graph, key), reduce: %{} do
      values ->
        case ChannelLookup.channel_for(graph, key) do
          nil ->
            Map.put(values, key, value)

          channel ->
            checkpoint = checkpoint_channel_value(channel, value)
            if checkpoint == Channel.missing(), do: values, else: Map.put(values, key, checkpoint)
        end
    end
  end

  @spec checkpoint_snapshot_values(StateGraph.t(), map(), [term()]) :: map()
  def checkpoint_snapshot_values(%StateGraph{} = graph, state, channels_to_snapshot) do
    requested = MapSet.new(channels_to_snapshot, &to_string/1)

    for {key, value} <- state,
        MapSet.member?(requested, to_string(key)),
        ChannelLookup.checkpointed_channel?(graph, key),
        match?(%DeltaChannel{}, ChannelLookup.channel_for(graph, key)),
        into: %{},
        do: {key, %DeltaSnapshot{value: value}}
  end

  # The writes of the step to each delta channel, one list entry per write.
  @spec checkpoint_channel_deltas(StateGraph.t(), map()) :: map()
  def checkpoint_channel_deltas(%StateGraph{channels: channels} = graph, step_update) do
    for {key, %DeltaChannel{}} <- channels,
        ChannelLookup.checkpointed_channel?(graph, key),
        {:ok, value} <- [state_channel_value(step_update, key)],
        into: %{},
        do: {to_string(key), ChannelMerge.step_writes(value)}
  end

  defp checkpoint_channel_value(channel, value) do
    channel
    |> Channel.copy()
    |> Channel.from_checkpoint(value)
    |> Channel.checkpoint()
  end

  defp state_channel_value(state, key) do
    with :error <- Map.fetch(state, key), do: Map.fetch(state, to_string(key))
  end
end
