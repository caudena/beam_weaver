defmodule BeamWeaver.Checkpoint.DeltaHistory do
  @moduledoc false

  alias BeamWeaver.Checkpoint
  alias BeamWeaver.Checkpoint.PendingWrite
  alias BeamWeaver.Graph.Channel
  alias BeamWeaver.Graph.Channels.DeltaSnapshot
  alias BeamWeaver.MapAccess

  @spec get(struct(), map(), [String.t()], keyword()) :: map()
  def get(saver, config, channel_names, _opts) do
    channels = Enum.map(channel_names, &to_string/1)
    initial = Map.new(channels, &{&1, %{seed: Channel.missing(), writes: []}})

    saver
    |> checkpoint_chain(config)
    |> Enum.reduce(initial, fn {tuple, include_pending?}, history ->
      Enum.reduce(channels, history, fn channel, acc ->
        acc
        |> apply_checkpoint(channel, tuple)
        |> append_pending_writes(channel, tuple, include_pending?)
      end)
    end)
  end

  defp checkpoint_chain(saver, config) do
    case Checkpoint.get_tuple(saver, config) do
      nil -> []
      tuple -> do_parent_chain(saver, tuple.parent_config, [{tuple, false}])
    end
  end

  defp do_parent_chain(_saver, nil, tuples), do: tuples

  defp do_parent_chain(saver, config, tuples) do
    case Checkpoint.get_tuple(saver, config) do
      nil -> tuples
      tuple -> do_parent_chain(saver, tuple.parent_config, [{tuple, true} | tuples])
    end
  end

  defp apply_checkpoint(history, channel, tuple) do
    missing = Channel.missing()

    case MapAccess.fetch(tuple.checkpoint["channel_values"], channel) do
      {:ok, value} when value != missing -> Map.put(history, channel, %{seed: unwrap_snapshot(value), writes: []})
      _missing -> append(history, channel, checkpoint_deltas(tuple, channel))
    end
  end

  defp checkpoint_deltas(tuple, channel) do
    configurable = tuple.config["configurable"]

    tuple.checkpoint["channel_deltas"]
    |> Map.get(channel, [])
    |> Enum.with_index(fn value, index ->
      %PendingWrite{
        thread_id: configurable["thread_id"],
        checkpoint_ns: configurable["checkpoint_ns"],
        checkpoint_id: configurable["checkpoint_id"],
        task_id: "__delta_checkpoint__",
        index: index,
        channel: channel,
        value: value,
        path: ""
      }
    end)
  end

  defp append_pending_writes(history, _channel, _tuple, false), do: history

  defp append_pending_writes(history, channel, tuple, true) do
    writes = tuple |> Map.get(:pending_write_records, []) |> Enum.filter(&(to_string(&1.channel) == channel))
    append(history, channel, writes)
  end

  defp append(history, channel, writes), do: update_in(history, [channel, :writes], &(&1 ++ writes))

  defp unwrap_snapshot(%DeltaSnapshot{value: value}), do: value
  defp unwrap_snapshot(%{"__beam_weaver_delta_snapshot__" => value}), do: value
  defp unwrap_snapshot(%{__beam_weaver_delta_snapshot__: value}), do: value
  defp unwrap_snapshot(value), do: value
end
