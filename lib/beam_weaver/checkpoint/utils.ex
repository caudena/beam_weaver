defmodule BeamWeaver.Checkpoint.Utils do
  @moduledoc """
  Pure checkpoint map helpers.
  """

  @spec empty_checkpoint(keyword() | map()) :: map()
  def empty_checkpoint(opts \\ []) do
    opts = if is_map(opts), do: Map.to_list(opts), else: opts

    %{
      "v" => Keyword.get(opts, :version, 1),
      "id" => Keyword.get_lazy(opts, :id, &generated_id/0),
      "ts" => Keyword.get_lazy(opts, :ts, fn -> DateTime.utc_now() |> DateTime.to_iso8601() end),
      "channel_values" => Keyword.get(opts, :channel_values, %{}),
      "channel_versions" => Keyword.get(opts, :channel_versions, %{}),
      "versions_seen" => Keyword.get(opts, :versions_seen, %{}),
      "pending_sends" => Keyword.get(opts, :pending_sends, []),
      "channel_deltas" => Keyword.get(opts, :channel_deltas, %{})
    }
    |> maybe_put_metadata(Keyword.get(opts, :metadata))
  end

  @spec from_channels(map(), keyword()) :: map()
  def from_channels(channels, opts \\ []) when is_map(channels) do
    channel_values = Map.new(channels, fn {key, value} -> {to_string(key), value} end)

    channel_versions =
      opts
      |> Keyword.get(:channel_versions, %{})
      |> case do
        versions when versions == %{} ->
          Map.new(channel_values, fn {key, _value} -> {key, 1} end)

        versions ->
          Map.new(versions, fn {key, value} -> {to_string(key), value} end)
      end

    opts
    |> Keyword.put(:channel_values, channel_values)
    |> Keyword.put(:channel_versions, channel_versions)
    |> empty_checkpoint()
  end

  @spec checkpoint_id(term()) :: term() | nil
  def checkpoint_id(%{checkpoint: checkpoint}), do: checkpoint_id(checkpoint)
  def checkpoint_id(%{"checkpoint" => checkpoint}), do: checkpoint_id(checkpoint)
  def checkpoint_id(%{config: config}), do: checkpoint_id(config)
  def checkpoint_id(%{"config" => config}), do: checkpoint_id(config)

  def checkpoint_id(%{} = value) do
    get_in(value, ["configurable", "checkpoint_id"]) ||
      get_in(value, [:configurable, :checkpoint_id]) ||
      Map.get(value, "checkpoint_id") ||
      Map.get(value, :checkpoint_id) ||
      Map.get(value, "id") ||
      Map.get(value, :id)
  end

  def checkpoint_id(_value), do: nil

  @spec metadata(term()) :: map()
  def metadata(%{metadata: metadata}) when is_map(metadata), do: metadata
  def metadata(%{"metadata" => metadata}) when is_map(metadata), do: metadata
  def metadata(%{} = value), do: Map.get(value, :metadata, Map.get(value, "metadata", %{})) || %{}
  def metadata(_value), do: %{}

  defp maybe_put_metadata(checkpoint, nil), do: checkpoint
  defp maybe_put_metadata(checkpoint, metadata), do: Map.put(checkpoint, "metadata", metadata)

  defp generated_id do
    "checkpoint_" <> Integer.to_string(System.unique_integer([:positive, :monotonic]), 36)
  end
end
