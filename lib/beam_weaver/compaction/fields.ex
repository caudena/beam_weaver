defmodule BeamWeaver.Compaction.Fields do
  @moduledoc false

  @spec normalize(map(), %{String.t() => atom()}) :: {:ok, map()} | {:error, :duplicate_field}
  def normalize(attrs, field_names) when is_map(attrs) and is_map(field_names) do
    Enum.reduce_while(attrs, {:ok, %{}}, fn {key, value}, {:ok, normalized} ->
      field = if is_binary(key), do: Map.get(field_names, key, key), else: key

      if Map.has_key?(normalized, field) do
        {:halt, {:error, :duplicate_field}}
      else
        {:cont, {:ok, Map.put(normalized, field, value)}}
      end
    end)
  end
end
