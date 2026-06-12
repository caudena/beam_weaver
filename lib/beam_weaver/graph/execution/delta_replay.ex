defmodule BeamWeaver.Graph.Execution.DeltaReplay do
  @moduledoc false

  alias BeamWeaver.Checkpoint
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Graph.Channel
  alias BeamWeaver.Graph.Channels.DeltaChannel
  alias BeamWeaver.Graph.StateGraph

  @spec restore_channel_values(map(), map(), map()) :: {:ok, map()} | {:error, Error.t()}
  def restore_channel_values(%{graph: %StateGraph{channels: channels}} = compiled, tuple, values) do
    Enum.reduce_while(channels, {:ok, values}, fn {key, channel}, {:ok, restored} ->
      cond do
        match?(%DeltaChannel{}, channel) ->
          case restore_delta_value(compiled, tuple, restored, key, channel) do
            {:ok, restored} -> {:cont, {:ok, restored}}
            {:error, %Error{} = error} -> {:halt, {:error, error}}
          end

        channel_value_missing?(restored, key) ->
          {:cont, {:ok, Map.delete(restored, key)}}

        true ->
          {:cont, {:ok, restored}}
      end
    end)
  end

  defp restore_delta_value(%{checkpointer: nil}, _tuple, values, _key, _channel), do: {:ok, values}

  defp restore_delta_value(%{} = compiled, tuple, values, key, channel) do
    history =
      compiled.checkpointer
      |> Checkpoint.get_delta_channel_history(tuple.config, [key])
      |> Map.get(to_string(key), %{seed: Channel.missing(), writes: []})

    replay_channel = Channel.from_checkpoint(channel, history.seed)

    {:ok, replayed, _changed?} = DeltaChannel.replay_writes(replay_channel, history.writes)

    case Channel.get(replayed) do
      {:ok, value} -> {:ok, Map.put(values, key, value)}
      {:error, %Error{type: :empty_channel}} -> {:ok, Map.delete(values, key)}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp channel_value_missing?(values, key) do
    Map.get(values, key) == Channel.missing() or
      Map.get(values, to_string(key)) == Channel.missing()
  end
end
