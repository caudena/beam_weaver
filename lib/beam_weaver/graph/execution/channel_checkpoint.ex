defmodule BeamWeaver.Graph.Execution.ChannelCheckpoint do
  @moduledoc false

  alias BeamWeaver.Graph.Channel
  alias BeamWeaver.Graph.Channels.DeltaChannel
  alias BeamWeaver.Graph.Channels.DeltaSnapshot
  alias BeamWeaver.Graph.Execution.ChannelLookup
  alias BeamWeaver.Graph.StateGraph

  @spec checkpoint_channel_values(StateGraph.t(), map()) :: map()
  def checkpoint_channel_values(%StateGraph{channels: channels} = graph, state) do
    Enum.reduce(state, %{}, fn {key, value}, values ->
      cond do
        ChannelLookup.private_channel?(graph, key) or ChannelLookup.managed_key?(graph, key) ->
          values

        node_outputs_key?(key) ->
          values

        true ->
          case ChannelLookup.channel_for(%StateGraph{channels: channels}, key) do
            nil ->
              Map.put(values, key, value)

            channel ->
              checkpoint = checkpoint_channel_value(channel, value)

              if checkpoint == Channel.missing(),
                do: values,
                else: Map.put(values, key, checkpoint)
          end
      end
    end)
  end

  @spec checkpoint_snapshot_values(StateGraph.t(), map(), [term()]) :: map()
  def checkpoint_snapshot_values(%StateGraph{} = graph, state, channels_to_snapshot) do
    requested = MapSet.new(channels_to_snapshot, &to_string/1)

    Enum.reduce(state, %{}, fn {key, value}, values ->
      cond do
        not MapSet.member?(requested, to_string(key)) ->
          values

        ChannelLookup.private_channel?(graph, key) ->
          values

        true ->
          case ChannelLookup.channel_for(graph, key) do
            %DeltaChannel{} -> Map.put(values, key, %DeltaSnapshot{value: value})
            _other -> values
          end
      end
    end)
  end

  @spec checkpoint_channel_deltas(StateGraph.t(), map()) :: map()
  def checkpoint_channel_deltas(%StateGraph{channels: channels} = graph, step_update) do
    Enum.reduce(channels, %{}, fn {key, channel}, deltas ->
      case {ChannelLookup.private_channel?(graph, key), channel, state_channel_value(step_update, key)} do
        {false, %DeltaChannel{}, {:ok, value}} ->
          Map.put(deltas, to_string(key), List.wrap(value))

        _other ->
          deltas
      end
    end)
  end

  defp checkpoint_channel_value(channel, value) do
    channel
    |> Channel.copy()
    |> Channel.from_checkpoint(value)
    |> Channel.checkpoint()
  end

  defp state_channel_value(state, key) do
    cond do
      Map.has_key?(state, key) ->
        {:ok, Map.fetch!(state, key)}

      Map.has_key?(state, to_string(key)) ->
        {:ok, Map.fetch!(state, to_string(key))}

      true ->
        :error
    end
  end

  defp node_outputs_key?(key) when key in [:__node_outputs__, "__node_outputs__"], do: true
  defp node_outputs_key?(_key), do: false
end
