defmodule BeamWeaver.Checkpoint.Normalization do
  @moduledoc false

  @spec configurable(map() | keyword()) :: map()
  def configurable(config) when is_list(config), do: configurable(Map.new(config))

  def configurable(%{} = config) do
    config
    |> Map.get(:configurable, Map.get(config, "configurable", config))
    |> stringify_config()
  end

  def normalize_tuple(nil, _saver), do: nil

  def normalize_tuple(%{checkpoint: checkpoint} = tuple, saver) when is_map(checkpoint) do
    tuple
    |> Map.put(:checkpoint, normalize_checkpoint(checkpoint))
    |> attach_parent_task_writes(saver)
  end

  def normalize_tuple(tuple, _saver), do: tuple

  def normalize_metadata(config, metadata) do
    metadata =
      config
      |> metadata_from_config()
      |> Map.merge(metadata || %{})

    # Metadata rarely holds a NUL byte; without one it is kept as it is
    # instead of being rebuilt.
    if nul_free?(metadata), do: metadata, else: sanitize_json_string_values(metadata)
  end

  defp stringify_config(config) when is_list(config), do: stringify_config(Map.new(config))

  defp stringify_config(config) when is_map(config), do: Map.new(config, fn {key, value} -> {to_string(key), value} end)

  defp stringify_config(_other), do: %{}

  defp normalize_checkpoint(checkpoint) do
    checkpoint
    |> Map.put_new("channel_values", %{})
    |> Map.put_new("channel_versions", %{})
    |> Map.put_new("versions_seen", %{})
    |> Map.put_new("pending_sends", [])
    |> Map.put_new("channel_deltas", %{})
  end

  defp attach_parent_task_writes(%{parent_config: parent_config} = tuple, saver)
       when is_map(parent_config) do
    {tuple, parent} = parent_pending_writes(tuple, saver, parent_config)

    task_values = for {_task_id, "__tasks__", value} <- parent, do: value

    if task_values == [] do
      tuple
    else
      checkpoint = tuple.checkpoint

      checkpoint =
        checkpoint
        |> put_in(
          ["channel_values", "__tasks__"],
          Map.get(checkpoint["channel_values"], "__tasks__", []) ++ task_values
        )
        |> put_in(
          ["channel_versions"],
          Map.put_new(checkpoint["channel_versions"], "__tasks__", checkpoint["id"])
        )

      %{tuple | checkpoint: checkpoint}
    end
  end

  defp attach_parent_task_writes(tuple, _saver), do: Map.delete(tuple, :parent_pending_writes)

  defp parent_pending_writes(tuple, saver, parent_config) do
    case Map.fetch(tuple, :parent_pending_writes) do
      {:ok, pending_writes} when is_list(pending_writes) ->
        {Map.delete(tuple, :parent_pending_writes), pending_writes}

      {:ok, _other} ->
        {Map.delete(tuple, :parent_pending_writes), []}

      :error ->
        parent =
          saver.__struct__.get_tuple(saver, parent_config)
          |> case do
            %{pending_writes: pending_writes} when is_list(pending_writes) -> pending_writes
            _other -> []
          end

        {tuple, parent}
    end
  end

  defp metadata_from_config(config) when is_list(config),
    do: metadata_from_config(Map.new(config))

  defp metadata_from_config(%{} = config) do
    config
    |> Map.get(:metadata, Map.get(config, "metadata", %{}))
    |> case do
      metadata when is_list(metadata) -> Map.new(metadata)
      metadata when is_map(metadata) -> metadata
      _other -> %{}
    end
  end

  # True when `sanitize_json_string_values/1` would return `value` unchanged.
  defp nul_free?(%_{}), do: true
  defp nul_free?(value) when is_binary(value), do: :binary.match(value, <<0>>) == :nomatch
  defp nul_free?(value) when is_list(value), do: nul_free_list?(value)

  defp nul_free?(value) when is_map(value),
    do: Enum.all?(value, fn {key, nested} -> nul_free_key?(key) and nul_free?(nested) end)

  defp nul_free?(_value), do: true

  defp nul_free_list?([]), do: true
  defp nul_free_list?([head | tail]), do: nul_free?(head) and nul_free_list?(tail)
  defp nul_free_list?(_improper_tail), do: false

  defp nul_free_key?(key) when is_binary(key), do: nul_free?(key)
  defp nul_free_key?(_key), do: true

  defp sanitize_json_string_values(%_{} = struct), do: struct

  defp sanitize_json_string_values(value) when is_binary(value) do
    String.replace(value, <<0>>, "")
  end

  defp sanitize_json_string_values(value) when is_list(value) do
    Enum.map(value, &sanitize_json_string_values/1)
  end

  defp sanitize_json_string_values(value) when is_map(value) do
    Map.new(value, fn {key, nested_value} ->
      {sanitize_json_key(key), sanitize_json_string_values(nested_value)}
    end)
  end

  defp sanitize_json_string_values(value), do: value

  defp sanitize_json_key(key) when is_binary(key), do: String.replace(key, <<0>>, "")
  defp sanitize_json_key(key), do: key
end
