defmodule BeamWeaver.Graph.Execution.ChannelLookup do
  @moduledoc false

  alias BeamWeaver.Graph.Channels.UntrackedValue
  alias BeamWeaver.Graph.StateGraph

  @spec channel_for(StateGraph.t(), atom() | String.t()) :: struct() | nil
  def channel_for(%StateGraph{channels: channels}, key) do
    Map.get(channels, key) ||
      Map.get(channels, to_string(key)) ||
      case key do
        key when is_binary(key) -> existing_atom(key) && Map.get(channels, existing_atom(key))
        _other -> nil
      end
  end

  @spec state_key_for_channel(map(), term()) :: term()
  def state_key_for_channel(state, channel) do
    Enum.find(Map.keys(state), &(to_string(&1) == to_string(channel))) ||
      existing_atom(channel) ||
      channel
  end

  @spec reducer_for(map(), term()) :: function() | nil
  def reducer_for(reducers, key), do: Map.get(reducers, key) || Map.get(reducers, to_string(key))

  @spec private_channel?(StateGraph.t(), term()) :: boolean()
  def private_channel?(%StateGraph{channel_visibility: visibility}, key) do
    Map.get(visibility, key) == :private or
      Map.get(visibility, to_string(key)) == :private or
      case key do
        key when is_binary(key) ->
          case existing_atom(key) do
            nil -> false
            atom -> Map.get(visibility, atom) == :private
          end

        _other ->
          false
      end
  end

  @spec managed_key?(StateGraph.t(), term()) :: boolean()
  def managed_key?(%StateGraph{managed: managed}, key) do
    Map.has_key?(managed, key) or
      Map.has_key?(managed, to_string(key)) or
      case key do
        key when is_binary(key) ->
          case existing_atom(key) do
            nil -> false
            atom -> Map.has_key?(managed, atom)
          end

        _other ->
          false
      end
  end

  @spec public_state(StateGraph.t(), map()) :: map()
  def public_state(%StateGraph{} = graph, state) do
    Map.reject(state, fn {key, _value} ->
      private_channel?(graph, key) or managed_key?(graph, key) or internal_key?(key)
    end)
  end

  @spec persisted_update(StateGraph.t(), map()) :: map()
  def persisted_update(%StateGraph{} = graph, update) when is_map(update) do
    Map.reject(update, fn {key, _value} ->
      private_channel?(graph, key) or managed_key?(graph, key) or
        node_outputs_key?(key) or
        match?(%UntrackedValue{}, channel_for(graph, key))
    end)
  end

  def persisted_update(_graph, update), do: update

  @spec existing_atom(term()) :: atom() | nil
  def existing_atom(channel) when is_binary(channel) do
    String.to_existing_atom(channel)
  rescue
    ArgumentError -> nil
  end

  def existing_atom(_channel), do: nil

  defp internal_key?(key) when key in [:__node_outputs__, :__edge_runs__], do: true
  defp internal_key?(key) when key in ["__node_outputs__", "__edge_runs__"], do: true
  defp internal_key?(_key), do: false

  defp node_outputs_key?(key) when key in [:__node_outputs__, "__node_outputs__"], do: true
  defp node_outputs_key?(_key), do: false
end
