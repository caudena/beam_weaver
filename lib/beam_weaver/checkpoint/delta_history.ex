defmodule BeamWeaver.Checkpoint.DeltaHistory do
  @moduledoc false

  alias BeamWeaver.Checkpoint
  alias BeamWeaver.Checkpoint.PendingWrite
  alias BeamWeaver.Graph.Channel
  alias BeamWeaver.Graph.Channels.DeltaSnapshot

  @spec get(struct(), map(), [String.t()], keyword()) :: map()
  def get(saver, config, channel_names, _opts \\ []) do
    channels = Enum.map(channel_names, &to_string/1)

    initial =
      Map.new(channels, fn channel ->
        {channel, %{seed: Channel.missing(), writes: []}}
      end)

    saver
    |> checkpoint_chain(config)
    |> Enum.reduce(initial, fn {tuple, include_pending?}, history ->
      Enum.reduce(channels, history, fn channel, acc ->
        acc
        |> maybe_set_seed(channel, tuple)
        |> append_checkpoint_deltas(channel, tuple)
        |> maybe_append_writes(channel, tuple, include_pending?)
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

  defp maybe_set_seed(history, channel, tuple) do
    values =
      Map.get(tuple.checkpoint, "channel_values", Map.get(tuple.checkpoint, :channel_values, %{}))

    case fetch_channel_value(values, channel) do
      {:ok, value} ->
        if value == Channel.missing(),
          do: history,
          else: put_in(history, [channel], %{seed: unwrap_snapshot(value), writes: []})

      _missing ->
        history
    end
  end

  defp append_writes(history, channel, tuple) do
    writes =
      tuple
      |> Map.get(:pending_write_records, [])
      |> Enum.filter(&(to_string(&1.channel) == channel))

    update_in(history, [channel, :writes], &((&1 || []) ++ writes))
  end

  defp maybe_append_writes(history, channel, tuple, true),
    do: append_writes(history, channel, tuple)

  defp maybe_append_writes(history, _channel, _tuple, false), do: history

  defp append_checkpoint_deltas(history, channel, tuple) do
    values =
      Map.get(tuple.checkpoint, "channel_values", Map.get(tuple.checkpoint, :channel_values, %{}))

    missing = Channel.missing()

    case fetch_channel_value(values, channel) do
      {:ok, ^missing} ->
        do_append_checkpoint_deltas(history, channel, tuple)

      {:ok, _value} ->
        history

      _missing ->
        do_append_checkpoint_deltas(history, channel, tuple)
    end
  end

  defp do_append_checkpoint_deltas(history, channel, tuple) do
    checkpoint_id = tuple.config["configurable"]["checkpoint_id"]
    namespace = tuple.config["configurable"]["checkpoint_ns"]
    thread_id = tuple.config["configurable"]["thread_id"]

    writes =
      tuple.checkpoint
      |> Map.get("channel_deltas", Map.get(tuple.checkpoint, :channel_deltas, %{}))
      |> Map.get(channel, [])
      |> Enum.with_index(fn value, index ->
        %PendingWrite{
          thread_id: thread_id,
          checkpoint_ns: namespace,
          checkpoint_id: checkpoint_id,
          task_id: "__delta_checkpoint__",
          index: index,
          channel: channel,
          value: value,
          path: ""
        }
      end)

    update_in(history, [channel, :writes], &((&1 || []) ++ writes))
  end

  defp fetch_channel_value(values, channel) do
    cond do
      Map.has_key?(values, channel) -> {:ok, Map.fetch!(values, channel)}
      existing = existing_atom(channel) -> Map.fetch(values, existing)
      true -> :error
    end
  end

  defp unwrap_snapshot(%DeltaSnapshot{value: value}), do: value
  defp unwrap_snapshot(%{"__beam_weaver_delta_snapshot__" => value}), do: value
  defp unwrap_snapshot(%{__beam_weaver_delta_snapshot__: value}), do: value
  defp unwrap_snapshot(value), do: value

  defp existing_atom(channel) do
    String.to_existing_atom(channel)
  rescue
    ArgumentError -> nil
  end
end
