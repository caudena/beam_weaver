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

  # The key under which the graph declares a channel, whether `key` names it
  # as an atom or as a string; nil for a key the graph doesn't declare.
  @spec channel_key(StateGraph.t(), term()) :: term() | nil
  def channel_key(%StateGraph{channels: channels}, key) do
    cond do
      Map.has_key?(channels, key) ->
        key

      is_atom(key) and Map.has_key?(channels, Atom.to_string(key)) ->
        Atom.to_string(key)

      is_binary(key) ->
        case existing_atom(key) do
          nil -> nil
          atom -> if Map.has_key?(channels, atom), do: atom
        end

      true ->
        nil
    end
  end

  # A state read back from a checkpoint, with every declared channel under the
  # graph's own key.
  @spec graph_keys(StateGraph.t(), map()) :: map()
  def graph_keys(%StateGraph{} = graph, state) when is_map(state) do
    Map.new(state, fn {key, value} -> {channel_key(graph, key) || key, value} end)
  end

  # Checkpoints saved as JSON before map keys kept their types gave every key
  # back as a string, and listed the names of the state's atom keys (and of a
  # `Send`'s update) next to it. This turns those keys back into atoms; a name
  # whose atom no longer exists stays a string.
  @spec restore_atom_keys(map(), [String.t()] | nil) :: map()
  def restore_atom_keys(map, [_first | _rest] = names) when is_map(map) do
    names = MapSet.new(names)

    Map.new(map, fn
      {key, value} when is_binary(key) ->
        if MapSet.member?(names, key), do: {existing_atom(key) || key, value}, else: {key, value}

      entry ->
        entry
    end)
  end

  def restore_atom_keys(map, _names), do: map

  @spec state_key_for_channel(map(), term()) :: term()
  def state_key_for_channel(state, channel) do
    Enum.find(Map.keys(state), &(to_string(&1) == to_string(channel))) ||
      existing_atom(channel) ||
      channel
  end

  @spec reducer_for(map(), term()) :: function() | nil
  def reducer_for(reducers, key), do: Map.get(reducers, key) || Map.get(reducers, to_string(key))

  # Private keys stay out of the output; only those declared with
  # `checkpoint: true` (`:private_checkpointed`) are saved in checkpoints.
  @spec private_channel?(StateGraph.t(), term()) :: boolean()
  def private_channel?(%StateGraph{} = graph, key),
    do: visibility(graph, key) in [:private, :private_checkpointed]

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

  # Drops the graph's bookkeeping channels (node outputs and edge run counts),
  # which no node or caller should read.
  @spec drop_internal_keys(map()) :: map()
  def drop_internal_keys(state) when is_map(state),
    do: Map.reject(state, fn {key, _value} -> internal_key?(key) end)

  @spec persisted_update(StateGraph.t(), map()) :: map()
  def persisted_update(%StateGraph{} = graph, update) when is_map(update) do
    Map.filter(update, fn {key, _value} -> checkpointed_channel?(graph, key) end)
  end

  def persisted_update(_graph, update), do: update

  @spec checkpointed_channel?(StateGraph.t(), term()) :: boolean()
  def checkpointed_channel?(%StateGraph{} = graph, key) do
    not (visibility(graph, key) == :private or managed_key?(graph, key) or
           node_outputs_key?(key) or match?(%UntrackedValue{}, channel_for(graph, key)))
  end

  @spec existing_atom(term()) :: atom() | nil
  def existing_atom(channel) when is_binary(channel) do
    String.to_existing_atom(channel)
  rescue
    ArgumentError -> nil
  end

  def existing_atom(_channel), do: nil

  defp internal_key?(key) when key in [:__node_outputs__, :__edge_runs__], do: true
  defp internal_key?(key) when key in ["__node_outputs__", "__edge_runs__"], do: true
  defp internal_key?("__barrier__:" <> _join), do: true
  defp internal_key?(_key), do: false

  defp node_outputs_key?(key) when key in [:__node_outputs__, "__node_outputs__"], do: true
  defp node_outputs_key?(_key), do: false

  defp visibility(%StateGraph{channel_visibility: visibility}, key) do
    Map.get(visibility, key) || Map.get(visibility, to_string(key)) ||
      if is_binary(key), do: Map.get(visibility, existing_atom(key))
  end
end
