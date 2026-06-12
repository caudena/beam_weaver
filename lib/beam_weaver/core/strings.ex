defmodule BeamWeaver.Core.Strings do
  @moduledoc """
  Small string helpers used at serialization and storage boundaries.

  These functions are intentionally plain functions instead of Python-style
  utility objects. They keep prompt/debug formatting and Postgres text
  sanitization consistent across adapters.
  """

  @doc """
  Joins any enumerable into a comma-separated string.
  """
  @spec comma_list(Enumerable.t()) :: String.t()
  def comma_list(items) do
    Enum.map_join(items, ", ", &to_string/1)
  end

  @doc """
  Formats a value into a compact prompt/debug string.
  """
  @spec stringify_value(term()) :: String.t()
  def stringify_value(value) when is_binary(value), do: value

  def stringify_value(%{__struct__: _module} = value) do
    value
    |> Map.from_struct()
    |> stringify_dict()
    |> prefix_nested()
  end

  def stringify_value(value) when is_map(value) do
    value
    |> stringify_dict()
    |> prefix_nested()
  end

  def stringify_value(value) when is_list(value) do
    Enum.map_join(value, "\n", &stringify_value/1)
  end

  def stringify_value(value), do: to_string(value)

  @doc """
  Formats a map as `key: value` lines.
  """
  @spec stringify_dict(map()) :: String.t()
  def stringify_dict(data) when is_map(data) do
    Enum.map_join(data, "", fn {key, value} ->
      "#{key}: #{stringify_value(value)}\n"
    end)
  end

  @doc """
  Removes or replaces NUL bytes before writing text into Postgres text fields.
  """
  @spec sanitize_for_postgres(String.t(), String.t()) :: String.t()
  def sanitize_for_postgres(text, replacement \\ "") when is_binary(text) do
    String.replace(text, <<0>>, replacement)
  end

  defp prefix_nested(""), do: ""
  defp prefix_nested(value), do: "\n" <> value
end
