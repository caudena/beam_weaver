defmodule BeamWeaver.Checkpoint.DeltaCompaction do
  @moduledoc false

  alias BeamWeaver.Graph.Channels.DeltaSnapshot

  @spec keep_ids([map()]) :: [String.t()]
  def keep_ids([]), do: []

  def keep_ids(records) do
    records = Enum.sort_by(records, &Map.get(&1, :commit_order, 0))
    latest = records |> List.last() |> checkpoint_id()

    cond do
      not Enum.any?(records, &delta_checkpoint?/1) ->
        MapSet.new([latest])

      snapshot_index = nearest_snapshot_index(records) ->
        records
        |> Enum.drop(snapshot_index)
        |> Enum.map(&checkpoint_id/1)
        |> Enum.uniq()

      true ->
        records
        |> Enum.map(&checkpoint_id/1)
        |> Enum.uniq()
    end
  end

  defp nearest_snapshot_index(records) do
    records
    |> Enum.with_index()
    |> Enum.reverse()
    |> Enum.find_value(fn {record, index} -> if snapshot_checkpoint?(record), do: index end)
  end

  defp delta_checkpoint?(record) do
    snapshot_checkpoint?(record) or
      record
      |> checkpoint()
      |> Map.get("channel_deltas", %{})
      |> non_empty_map?()
  end

  defp snapshot_checkpoint?(nil), do: false

  defp snapshot_checkpoint?(record) do
    record
    |> checkpoint()
    |> Map.get("channel_values", %{})
    |> Enum.any?(fn {_key, value} -> delta_snapshot?(value) end)
  end

  defp delta_snapshot?(%DeltaSnapshot{}), do: true
  defp delta_snapshot?(%{"__beam_weaver_delta_snapshot__" => _value}), do: true
  defp delta_snapshot?(%{__beam_weaver_delta_snapshot__: _value}), do: true
  defp delta_snapshot?(_value), do: false

  defp non_empty_map?(map) when is_map(map), do: map_size(map) > 0
  defp non_empty_map?(_value), do: false

  defp checkpoint_id(record), do: checkpoint(record)["id"]
  defp checkpoint(%{checkpoint: checkpoint}), do: checkpoint
end
