defmodule BeamWeaver.Graph.Execution.ChannelMerge do
  @moduledoc false

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Graph.Channel
  alias BeamWeaver.Graph.Channels.BinaryOperatorAggregate
  alias BeamWeaver.Graph.Channels.DeltaChannel
  alias BeamWeaver.Graph.Channels.LastValue
  alias BeamWeaver.Graph.Execution.ChannelLookup
  alias BeamWeaver.Graph.Execution.Step
  alias BeamWeaver.Graph.Execution.TaskRequest
  alias BeamWeaver.Graph.Overwrite
  alias BeamWeaver.Graph.StateGraph

  @skip :__beam_weaver_skip_channel__

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
        state -> put_state_value(state, key, value, graph)
      end
    end)
    |> wrap_state_result()
  end

  def merge_update_result(state, update, reducers) do
    Enum.reduce(update || %{}, state, fn {key, value}, acc ->
      case acc do
        {:error, %Error{}} = error -> error
        state -> put_state_value(state, key, value, reducers)
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
    |> group_step_updates()
    |> Enum.reduce_while({:ok, %{}, state}, fn {key, values}, {:ok, step_update, next_state} ->
      case merge_step_channel(key, values, state, graph_or_reducers) do
        {:ok, step_value, state_value} ->
          {step_update, next_state} =
            case {step_value, state_value} do
              {@skip, @skip} ->
                {step_update, next_state}

              {@skip, state_value} ->
                {step_update, Map.put(next_state, key, state_value)}

              {step_value, state_value} ->
                {Map.put(step_update, key, step_value), Map.put(next_state, key, state_value)}
            end

          {:cont, {:ok, step_update, next_state}}

        {:error, %Error{} = error} ->
          {:halt, {:error, error}}
      end
    end)
  end

  @spec ready_state(term(), map(), StateGraph.t()) :: term()
  def ready_state(
        %TaskRequest{kind: :send, update: %{__struct__: _module} = update},
        _state,
        _graph
      ),
      do: update

  def ready_state(%TaskRequest{kind: :send, update: update}, _state, _graph)
      when not is_map(update),
      do: update

  def ready_state(ready, state, graph),
    do: merge_update(state, TaskRequest.update(ready), graph)

  defp wrap_state_result({:error, %Error{}} = error), do: error
  defp wrap_state_result(state), do: {:ok, state}

  defp group_step_updates(updates) do
    updates
    |> Enum.reduce(%{}, fn update, grouped ->
      Enum.reduce(update || %{}, grouped, fn {key, value}, acc ->
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
        merge_reducer_channel(key, values, Map.fetch(state, key), reducer)
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
    step_channel =
      channel
      |> Channel.copy()
      |> Channel.from_checkpoint(Channel.missing())

    state_checkpoint =
      state
      |> Map.fetch(key)
      |> case do
        {:ok, value} -> value
        :error -> Channel.missing()
      end

    state_channel =
      channel
      |> Channel.copy()
      |> Channel.from_checkpoint(state_checkpoint)

    with {:ok, step_channel, _step_changed?} <- Channel.update(step_channel, values),
         {:ok, state_channel, _state_changed?} <- Channel.update(state_channel, values) do
      case {step_channel_result(channel, step_channel, values), Channel.get(state_channel)} do
        {{:ok, step_value}, {:ok, state_value}} ->
          {:ok, step_value, unwrap_overwrite(state_value)}

        {{:error, %Error{type: :empty_channel}}, {:error, %Error{type: :empty_channel}}} ->
          {:ok, @skip, @skip}

        {{:error, %Error{type: :empty_channel}}, {:ok, state_value}} ->
          {:ok, @skip, unwrap_overwrite(state_value)}

        {{:error, %Error{} = error}, _state_result} ->
          {:error, error}

        {_step_result, {:error, %Error{} = error}} ->
          {:error, error}
      end
    end
  end

  defp step_channel_result(%DeltaChannel{}, _step_channel, []),
    do: {:error, Error.new(:empty_channel, "channel has no value")}

  defp step_channel_result(%DeltaChannel{}, _step_channel, [value]), do: {:ok, value}
  defp step_channel_result(%DeltaChannel{}, _step_channel, values), do: {:ok, values}
  defp step_channel_result(_channel, step_channel, _values), do: Channel.get(step_channel)

  defp unwrap_overwrite(%Overwrite{value: value}), do: value
  defp unwrap_overwrite(value), do: value

  defp put_state_value(state, key, value, %StateGraph{} = graph) do
    case ChannelLookup.channel_for(graph, key) do
      nil ->
        put_state_value(state, key, value, graph.reducers)

      channel ->
        case merge_declared_channel(key, [value], state, channel) do
          {:ok, @skip, _state_value} -> state
          {:ok, _step_value, state_value} -> Map.put(state, key, state_value)
          {:error, %Error{} = error} -> {:error, error}
        end
    end
  end

  defp put_state_value({:error, %Error{}} = error, _key, _value, _graph_or_reducers), do: error

  defp put_state_value(state, key, %Overwrite{value: value}, _reducers),
    do: Map.put(state, key, value)

  defp put_state_value(state, key, value, reducers) do
    reducer = ChannelLookup.reducer_for(reducers, key)

    if reducer && Map.has_key?(state, key) do
      Map.put(state, key, reducer.(Map.get(state, key), value))
    else
      Map.put(state, key, value)
    end
  end
end
