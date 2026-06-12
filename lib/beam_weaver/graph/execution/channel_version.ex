defmodule BeamWeaver.Graph.Execution.ChannelVersion do
  @moduledoc false

  alias BeamWeaver.Checkpoint
  alias BeamWeaver.Graph.Channel
  alias BeamWeaver.Graph.Execution.ChannelLookup

  @spec normalize(map() | nil) :: map()
  def normalize(versions) when is_map(versions) do
    Map.new(versions, fn {key, value} -> {to_string(key), value} end)
  end

  def normalize(_versions), do: %{}

  @spec bump(struct() | nil, map(), Enumerable.t()) :: map()
  def bump(nil, previous_versions, _changed_channels), do: normalize(previous_versions)

  def bump(checkpointer, previous_versions, changed_channels) do
    previous_versions = normalize(previous_versions)

    changed_channels
    |> Enum.map(&to_string/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.reduce(previous_versions, fn channel, versions ->
      current = Map.get(versions, channel)
      Map.put(versions, channel, Checkpoint.next_version(checkpointer, current, channel))
    end)
  end

  @spec bump(struct() | nil, map(), Enumerable.t(), map() | nil) :: map()
  def bump(nil, previous_versions, _changed_channels, _graph), do: normalize(previous_versions)

  def bump(checkpointer, previous_versions, changed_channels, graph) do
    previous_versions = normalize(previous_versions)

    changed_channels
    |> Enum.map(&to_string/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.reduce(previous_versions, fn channel, versions ->
      channel_struct = channel_struct(graph, channel)
      current = Map.get(versions, channel, null_version(channel_struct))
      version_key = channel_struct || channel
      Map.put(versions, channel, Checkpoint.next_version(checkpointer, current, version_key))
    end)
  end

  @spec changed?(map(), map(), term()) :: boolean()
  def changed?(previous_versions, next_versions, channel) do
    channel = to_string(channel)
    Map.get(normalize(previous_versions), channel) != Map.get(normalize(next_versions), channel)
  end

  @spec changed?(map(), map(), term(), map() | nil) :: boolean()
  def changed?(previous_versions, next_versions, channel, graph) do
    channel_name = to_string(channel)
    channel_struct = channel_struct(graph, channel_name)

    previous =
      Map.get(normalize(previous_versions), channel_name, null_version(channel_struct))

    next =
      Map.get(normalize(next_versions), channel_name, null_version(channel_struct))

    not version_equal?(channel_struct, previous, next)
  end

  defp channel_struct(nil, _channel), do: nil

  defp channel_struct(graph, channel) do
    ChannelLookup.channel_for(graph, channel)
  end

  defp null_version(nil), do: nil
  defp null_version(channel), do: Channel.null_version(channel)

  defp version_equal?(nil, left, right), do: left == right
  defp version_equal?(channel, left, right), do: Channel.version_equal?(channel, left, right)
end
