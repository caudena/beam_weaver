defmodule BeamWeaver.Graph.Execution.ChannelMerge do
  @moduledoc false

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Graph.Channel
  alias BeamWeaver.Graph.Channels.BinaryOperatorAggregate
  alias BeamWeaver.Graph.Channels.DeltaChannel
  alias BeamWeaver.Graph.Channels.LastValue
  alias BeamWeaver.Graph.Channels.NamedBarrierValue
  alias BeamWeaver.Graph.Execution.ChannelLookup
  alias BeamWeaver.Graph.Execution.Step
  alias BeamWeaver.Graph.Execution.TaskRequest
  alias BeamWeaver.Graph.Overwrite
  alias BeamWeaver.Graph.StateGraph

  # A step value that is left out of the step's update.
  @skip :__beam_weaver_skip_channel__
  # A state value that removes the key from the state.
  @delete :__beam_weaver_delete_channel__

  @spec merge_update(map(), map() | nil, StateGraph.t() | map()) :: map()
  def merge_update(state, update, graph_or_reducers) do
    case merge_update_result(state, update, graph_or_reducers) do
      {:ok, state} -> state
      {:error, %Error{} = error} -> raise RuntimeError, message: error.message
    end
  end

  @spec merge_update_result(map(), map() | nil, StateGraph.t() | map()) ::
          {:ok, map()} | {:error, Error.t()}
  def merge_update_result(state, update, %StateGraph{} = graph) do
    Enum.reduce(update || %{}, state, fn {key, value}, acc ->
      case acc do
        {:error, %Error{}} = error -> error
        state -> put_state_value(state, canonical_key(graph, state, key), value, graph)
      end
    end)
    |> wrap_state_result()
  end

  def merge_update_result(state, update, reducers) do
    Enum.reduce(update || %{}, state, fn {key, value}, acc ->
      case acc do
        {:error, %Error{}} = error -> error
        state -> put_state_value(state, canonical_key(reducers, state, key), value, reducers)
      end
    end)
    |> wrap_state_result()
  end

  @spec apply_pending_writes(map(), list(), StateGraph.t()) :: {:ok, map()} | {:error, Error.t()}
  def apply_pending_writes(state, [], _graph), do: {:ok, state}

  def apply_pending_writes(state, pending_writes, graph) do
    updates =
      Enum.flat_map(pending_writes, fn
        {_task_id, channel, value} ->
          if Step.reserved_channel?(channel),
            do: [],
            else: [%{ChannelLookup.state_key_for_channel(state, channel) => value}]

        {_task_id, channel, value, _path} ->
          if Step.reserved_channel?(channel),
            do: [],
            else: [%{ChannelLookup.state_key_for_channel(state, channel) => value}]

        _other ->
          []
      end)

    case merge_step_updates(state, updates, graph) do
      {:ok, _step_update, next_state} -> {:ok, next_state}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  @spec merge_step_updates(map(), [map()], StateGraph.t() | map()) ::
          {:ok, map(), map()} | {:error, Error.t()}
  def merge_step_updates(state, updates, graph_or_reducers) do
    updates
    |> group_step_updates(graph_or_reducers, state)
    |> Enum.reduce_while({:ok, %{}, state}, fn {key, values}, {:ok, step_update, next_state} ->
      case merge_step_channel(key, values, state, graph_or_reducers) do
        {:ok, step_value, state_value} ->
          {:cont, {:ok, put_step_value(step_update, key, step_value), apply_state_value(next_state, key, state_value)}}

        {:error, %Error{} = error} ->
          {:halt, {:error, error}}
      end
    end)
  end

  @doc false
  # Applies the writes of a finished step. On top of `merge_step_updates/3` it
  # fires every join whose upstream nodes have all arrived (the join's channel
  # then appears in the step's update, which schedules its node), and it tells
  # the channels nothing wrote to that a step has passed, which clears values
  # that last one step, such as an `EphemeralValue`. `also_written` names keys
  # written for this step before it ran: the writes replayed from a step that
  # failed or paused.
  @spec apply_step_writes(map(), [map()], StateGraph.t(), Enumerable.t()) ::
          {:ok, map(), map()} | {:error, Error.t()}
  def apply_step_writes(state, updates, %StateGraph{} = graph, also_written \\ []) do
    with {:ok, step_update, next_state} <- merge_step_updates(state, updates, graph),
         {step_update, next_state} = fire_joins(step_update, next_state, graph),
         {:ok, next_state} <-
           advance_unwritten_channels(next_state, graph, written_keys(updates, also_written)) do
      {:ok, step_update, next_state}
    end
  end

  # The state a task's node reads: the run's state with the task's `Send`
  # update merged in. A `Send` whose update is a struct, or not a map, hands
  # it to the node as it is.
  @spec ready_state(term(), map(), StateGraph.t()) :: {:ok, term()} | {:error, Error.t()}
  def ready_state(
        %TaskRequest{kind: :send, update: %{__struct__: _module} = update},
        _state,
        _graph
      ),
      do: {:ok, update}

  def ready_state(%TaskRequest{kind: :send, update: update}, _state, _graph)
      when not is_map(update),
      do: {:ok, update}

  def ready_state(ready, state, graph), do: merge_update_result(state, TaskRequest.update(ready), graph)

  defp wrap_state_result({:error, %Error{}} = error), do: error
  defp wrap_state_result(state), do: {:ok, state}

  defp group_step_updates(updates, graph_or_reducers, state) do
    updates
    |> Enum.reduce(%{}, fn update, grouped ->
      Enum.reduce(update || %{}, grouped, fn {key, value}, acc ->
        key = canonical_key(graph_or_reducers, state, key)
        Map.update(acc, key, [value], &[value | &1])
      end)
    end)
    |> Map.new(fn {key, values} -> {key, Enum.reverse(values)} end)
  end

  defp merge_step_channel(key, values, state, %StateGraph{} = graph) do
    case ChannelLookup.channel_for(graph, key) do
      nil ->
        merge_step_channel(key, values, state, graph.reducers)

      channel ->
        merge_declared_channel(key, values, state, channel)
    end
  end

  defp merge_step_channel(key, values, state, reducers) do
    case ChannelLookup.reducer_for(reducers, key) do
      nil ->
        merge_last_value_channel(key, values)

      reducer ->
        merge_reducer_channel(key, values, fetch_state_key(state, key), reducer)
    end
  end

  defp merge_last_value_channel(key, values) do
    channel = LastValue.new(key: key)

    with {:ok, channel, true} <- Channel.update(channel, values),
         {:ok, value} <- Channel.get(channel) do
      {:ok, value, unwrap_overwrite(value)}
    end
  end

  defp merge_reducer_channel(key, values, :error, reducer) do
    step_channel = BinaryOperatorAggregate.new(reducer, key: key)
    state_channel = BinaryOperatorAggregate.new(reducer, key: key)

    with {:ok, step_channel, true} <- Channel.update(step_channel, values),
         {:ok, state_channel, true} <- Channel.update(state_channel, values),
         {:ok, step_value} <- Channel.get(step_channel),
         {:ok, state_value} <- Channel.get(state_channel) do
      {:ok, step_value, state_value}
    end
  end

  defp merge_reducer_channel(key, values, {:ok, current_value}, reducer) do
    step_channel = BinaryOperatorAggregate.new(reducer, key: key)
    state_channel = BinaryOperatorAggregate.new(reducer, key: key, initial: current_value)

    with {:ok, step_channel, true} <- Channel.update(step_channel, values),
         {:ok, state_channel, true} <- Channel.update(state_channel, values),
         {:ok, step_value} <- Channel.get(step_channel),
         {:ok, state_value} <- Channel.get(state_channel) do
      {:ok, step_value, state_value}
    end
  end

  defp merge_declared_channel(key, values, state, channel) do
    with {:ok, state_value} <- next_state_value(key, values, state, channel),
         {:ok, step_value} <- step_value(channel, values) do
      {:ok, step_value, state_value}
    end
  end

  # The channel's value after the writes, restored from the value in `state`.
  defp next_state_value(key, values, state, channel) do
    with {:ok, updated, _changed?} <- Channel.update(restore_channel(channel, state, key), values) do
      state_value(updated)
    end
  end

  defp restore_channel(channel, state, key) do
    case fetch_state_key(state, key) do
      {:ok, value} -> Channel.from_checkpoint(channel, value)
      :error -> Channel.from_checkpoint(channel, Channel.missing())
    end
  end

  # A join keeps the names of the upstream nodes that arrived so far, so that it
  # still fires when they finish in different steps or in different runs of a
  # thread.
  defp state_value(%NamedBarrierValue{} = channel) do
    case Channel.checkpoint(channel) do
      [] -> {:ok, @delete}
      arrived -> {:ok, arrived}
    end
  end

  defp state_value(channel) do
    case Channel.get(channel) do
      {:ok, value} -> {:ok, unwrap_overwrite(value)}
      {:error, %Error{type: :empty_channel}} -> {:ok, @delete}
      {:error, %Error{}} = error -> error
    end
  end

  # What the step's own writes amount to, without the channel's earlier value:
  # the value the step reports in its update.
  defp step_value(%DeltaChannel{}, [value]), do: {:ok, value}
  defp step_value(%DeltaChannel{}, values), do: {:ok, values}

  # A join is reported when it fires, at the end of the step.
  defp step_value(%NamedBarrierValue{}, _values), do: {:ok, @skip}

  # A reducer's writes are folded from the first write, never from the
  # channel's starting value: a write such as a message removal only makes
  # sense against the state. Writes that can't be folded on their own are
  # reported as they are.
  defp step_value(%BinaryOperatorAggregate{} = channel, values) do
    channel = %{channel | value: Channel.missing(), initial: Channel.missing()}

    case Channel.update(channel, values) do
      {:ok, folded, _changed?} -> step_channel_value(folded)
      {:error, %Error{}} -> {:ok, values}
    end
  end

  defp step_value(channel, values) do
    with {:ok, step_channel, _changed?} <-
           Channel.update(Channel.from_checkpoint(channel, Channel.missing()), values) do
      step_channel_value(step_channel)
    end
  end

  defp step_channel_value(channel) do
    case Channel.get(channel) do
      {:ok, value} -> {:ok, value}
      {:error, %Error{type: :empty_channel}} -> {:ok, @skip}
      {:error, %Error{}} = error -> error
    end
  end

  defp put_step_value(step_update, _key, @skip), do: step_update
  defp put_step_value(step_update, key, value), do: Map.put(step_update, key, value)

  defp apply_state_value(state, key, @delete), do: delete_state_key(state, key)
  defp apply_state_value(state, key, value), do: put_state_key(state, key, value)

  # Fires every join whose upstream nodes have all arrived: its channel leaves
  # the state and appears in the step's update, which schedules its node.
  @spec fire_joins(map(), map(), StateGraph.t()) :: {map(), map()}
  def fire_joins(step_update, state, %StateGraph{waiting_edges: waiting_edges, channels: channels}) do
    Enum.reduce(waiting_edges, {step_update, state}, fn %{channel: key}, {step_update, state} ->
      if join_ready?(Map.get(channels, key), Map.fetch(state, key)) do
        {Map.put(step_update, key, nil), Map.delete(state, key)}
      else
        {step_update, state}
      end
    end)
  end

  defp join_ready?(%NamedBarrierValue{} = channel, {:ok, arrived}),
    do: channel |> Channel.from_checkpoint(arrived) |> Channel.available?()

  defp join_ready?(_channel, _arrived), do: false

  defp advance_unwritten_channels(state, %StateGraph{channels: channels}, written) do
    Enum.reduce_while(channels, {:ok, state}, fn {key, channel}, {:ok, state} ->
      with false <- MapSet.member?(written, to_string(key)),
           {:ok, value} <- fetch_state_key(state, key),
           {:ok, advanced, true} <- Channel.update(Channel.from_checkpoint(channel, value), []) do
        case state_value(advanced) do
          {:ok, state_value} -> {:cont, {:ok, apply_state_value(state, key, state_value)}}
          {:error, %Error{}} = error -> {:halt, error}
        end
      else
        {:error, %Error{}} = error -> {:halt, error}
        _unchanged -> {:cont, {:ok, state}}
      end
    end)
  end

  defp written_keys(updates, also_written) do
    updates
    |> Enum.flat_map(&Map.keys(&1 || %{}))
    |> Enum.concat(also_written)
    |> MapSet.new(&to_string/1)
  end

  defp unwrap_overwrite(%Overwrite{value: value}), do: value
  defp unwrap_overwrite(value), do: value

  defp put_state_value(state, key, value, %StateGraph{} = graph) do
    case ChannelLookup.channel_for(graph, key) do
      nil ->
        put_state_value(state, key, value, graph.reducers)

      channel ->
        case next_state_value(key, [value], state, channel) do
          {:ok, state_value} -> apply_state_value(state, key, state_value)
          {:error, %Error{} = error} -> {:error, error}
        end
    end
  end

  defp put_state_value({:error, %Error{}} = error, _key, _value, _graph_or_reducers), do: error

  defp put_state_value(state, key, %Overwrite{value: value}, _reducers),
    do: put_state_key(state, key, value)

  defp put_state_value(state, key, value, reducers) do
    reducer = ChannelLookup.reducer_for(reducers, key)

    case {reducer, fetch_state_key(state, key)} do
      {reducer, {:ok, current}} when is_function(reducer, 2) ->
        put_state_key(state, key, reducer.(current, value))

      _other ->
        put_state_key(state, key, value)
    end
  end

  defp canonical_key(%StateGraph{} = graph, _state, key) do
    ChannelLookup.channel_key(graph, key) || key
  end

  defp canonical_key(reducers, state, key) when is_map(reducers) do
    cond do
      Map.has_key?(reducers, key) ->
        key

      is_atom(key) and Map.has_key?(reducers, Atom.to_string(key)) ->
        Atom.to_string(key)

      (is_binary(key) and existing_atom(key)) && Map.has_key?(reducers, existing_atom(key)) ->
        existing_atom(key)

      Map.has_key?(state, key) ->
        key

      is_atom(key) and Map.has_key?(state, Atom.to_string(key)) ->
        Atom.to_string(key)

      (is_binary(key) and existing_atom(key)) && Map.has_key?(state, existing_atom(key)) ->
        existing_atom(key)

      true ->
        key
    end
  end

  defp canonical_key(_graph_or_reducers, _state, key), do: key

  defp fetch_state_key(state, key) when is_map(state) do
    cond do
      Map.has_key?(state, key) ->
        {:ok, Map.fetch!(state, key)}

      is_atom(key) and Map.has_key?(state, Atom.to_string(key)) ->
        {:ok, Map.fetch!(state, Atom.to_string(key))}

      is_binary(key) ->
        case existing_atom(key) do
          nil ->
            :error

          atom ->
            if Map.has_key?(state, atom), do: {:ok, Map.fetch!(state, atom)}, else: :error
        end

      true ->
        :error
    end
  end

  defp fetch_state_key(_state, _key), do: :error

  defp put_state_key(state, key, value) do
    state
    |> delete_state_key_aliases(key)
    |> Map.put(key, value)
  end

  defp delete_state_key(state, key) do
    state
    |> delete_state_key_aliases(key)
    |> Map.delete(key)
  end

  defp delete_state_key_aliases(state, key) when is_atom(key) do
    Map.delete(state, Atom.to_string(key))
  end

  defp delete_state_key_aliases(state, key) when is_binary(key) do
    case existing_atom(key) do
      nil -> state
      atom -> Map.delete(state, atom)
    end
  end

  defp delete_state_key_aliases(state, _key), do: state

  defp existing_atom(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> nil
  end
end
