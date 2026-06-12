defmodule BeamWeaver.Provider.Options do
  @moduledoc false

  @doc false
  def put_optional(map, key, value), do: BeamWeaver.MapShape.put_optional(map, key, value)

  @doc false
  def put_explicit_optional(map, key, opts, opt_key) when is_list(opts) do
    if Keyword.has_key?(opts, opt_key) do
      Map.put(map, key, Keyword.get(opts, opt_key))
    else
      map
    end
  end

  @doc false
  def option(model, opts, key), do: Keyword.get(opts, key, Map.get(model, key))

  @doc false
  def default_transport(nil), do: BeamWeaver.Transport.ReqFinch
  def default_transport(transport), do: transport

  @doc false
  def merge_optional_map(map, nil), do: map

  def merge_optional_map(map, value) when is_map(value),
    do: Map.merge(map, stringify_keys(value))

  @doc false
  def empty_to_nil(map) when is_map(map) and map_size(map) == 0, do: nil
  def empty_to_nil(map), do: map

  @doc false
  def merge_extra_body(body, nil), do: body
  def merge_extra_body(body, extra_body) when map_size(extra_body) == 0, do: body

  def merge_extra_body(body, extra_body) when is_map(extra_body),
    do: Map.merge(body, stringify_keys(extra_body))

  @doc false
  def reject_nil_values(map) when is_map(map) do
    BeamWeaver.MapShape.reject_nil_values(map)
  end

  @doc false
  def stringify_keys(map) when is_map(map) do
    BeamWeaver.MapShape.stringify_keys(map)
  end

  @doc false
  def stringify_value(value), do: BeamWeaver.MapShape.normalize_value(value)

  @doc false
  def normalize_option_map(nil), do: nil
  def normalize_option_map(value) when is_map(value), do: stringify_keys(value)

  @doc false
  def normalize_option_list(nil), do: nil
  def normalize_option_list(values) when is_list(values), do: Enum.map(values, &normalize_value/1)

  @doc false
  def normalize_value(value), do: BeamWeaver.MapShape.normalize_value(value)
end
