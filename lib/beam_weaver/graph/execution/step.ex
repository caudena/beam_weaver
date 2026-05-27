defmodule BeamWeaver.Graph.Execution.Step do
  @moduledoc """
  Pure graph execution step helpers.

  This module translates the important `langgraph.pregel._algo.apply_writes`
  invariants into immutable Elixir data transformations.
  """

  alias BeamWeaver.Graph.Execution

  @reserved_channels [
    "__error__",
    "__error_source_node__",
    "__interrupt__",
    "__no_writes__",
    "__push__",
    "__resume__",
    "__return__"
  ]

  @type task_write :: %{task_id: String.t(), channel: String.t(), value: term(), path: String.t()}

  @spec reserved_channel?(term()) :: boolean()
  def reserved_channel?(channel), do: to_string(channel) in @reserved_channels

  @spec control_channels() :: [String.t()]
  def control_channels, do: @reserved_channels

  @spec apply_writes(map(), [map()], keyword()) :: map()
  def apply_writes(state, tasks, opts \\ []) do
    reducers = Keyword.get(opts, :reducers, %{})
    previous_versions = Keyword.get(opts, :channel_versions, %{})
    checkpointer = Keyword.get(opts, :checkpointer)
    previous_seen = Keyword.get(opts, :versions_seen, %{})

    ordered_tasks = Enum.sort_by(tasks, &Map.get(&1, :path, ""))

    triggers_by_node =
      Map.new(ordered_tasks, &{to_string(Map.get(&1, :node)), Map.get(&1, :triggers, [])})

    writes =
      ordered_tasks
      |> Enum.flat_map(&Map.get(&1, :writes, []))
      |> Enum.reject(fn write -> reserved_channel?(Map.get(write, :channel)) end)

    updated_channels =
      writes
      |> Enum.map(&Map.get(&1, :channel))
      |> Execution.normalize_channels()

    %{
      state: apply_state_writes(state, writes, reducers),
      channel_versions: Execution.next_channel_versions(checkpointer, previous_versions, updated_channels),
      versions_seen: mark_seen(previous_seen, triggers_by_node, previous_versions),
      updated_channels: updated_channels
    }
  end

  defp apply_state_writes(state, writes, reducers) do
    updates =
      Enum.map(writes, fn %{channel: channel, value: value} ->
        {state_key_for_channel(state, channel), value}
      end)

    Enum.reduce(updates, state, fn {key, value}, acc ->
      case BeamWeaver.MapAccess.get(reducers, key) do
        reducer when is_function(reducer, 2) and is_map_key(acc, key) ->
          Map.put(acc, key, reducer.(Map.fetch!(acc, key), value))

        _other ->
          Map.put(acc, key, value)
      end
    end)
  end

  defp mark_seen(versions_seen, triggers_by_node, channel_versions) do
    Enum.reduce(triggers_by_node, versions_seen, fn {node, triggers}, seen ->
      trigger_versions =
        triggers
        |> Execution.normalize_channels()
        |> Map.new(fn channel -> {channel, Map.get(channel_versions, channel)} end)
        |> Enum.reject(fn {_channel, version} -> is_nil(version) end)
        |> Map.new()

      Map.update(seen, node, trigger_versions, &Map.merge(&1, trigger_versions))
    end)
  end

  defp state_key_for_channel(state, channel) do
    Enum.find(Map.keys(state), &(to_string(&1) == to_string(channel))) ||
      existing_atom(channel) ||
      channel
  end

  defp existing_atom(channel) when is_binary(channel) do
    String.to_existing_atom(channel)
  rescue
    ArgumentError -> nil
  end

  defp existing_atom(_channel), do: nil
end
