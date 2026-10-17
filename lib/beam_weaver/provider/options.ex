defmodule BeamWeaver.Provider.Options do
  @moduledoc false

  @doc false
  def put_optional(map, key, value), do: BeamWeaver.MapShape.put_optional(map, key, value)

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

  # The raw request-body fields for one call: the model's `extra_body` with the
  # call's `:extra_body` option merged over it, key by key. Builders merge the
  # result into the request body last (see `merge_extra_body/3`).
  @doc false
  def extra_body(model, opts) do
    model
    |> Map.get(:extra_body)
    |> Kernel.||(%{})
    |> stringify_keys()
    |> Map.merge(stringify_keys(Keyword.get(opts, :extra_body) || %{}))
  end

  @doc false
  def merge_extra_body(body, nil), do: body
  def merge_extra_body(body, extra_body) when map_size(extra_body) == 0, do: body

  def merge_extra_body(body, extra_body) when is_map(extra_body),
    do: Map.merge(body, stringify_keys(extra_body))

  @doc false
  def merge_extra_body(body, nil, _opts) when is_map(body), do: body

  def merge_extra_body(body, extra_body, opts)
      when is_map(body) and is_map(extra_body) and is_list(opts) do
    reserved = opts |> Keyword.get(:reserved, []) |> Enum.map(&to_string/1)
    extra_body = extra_body |> stringify_keys() |> Map.drop(reserved)

    Map.merge(body, extra_body)
  end

  @doc false
  def reject_nil_values(map) when is_map(map) do
    BeamWeaver.MapShape.reject_nil_values(map)
  end

  @doc false
  def stringify_keys(map) when is_map(map) do
    BeamWeaver.MapShape.stringify_keys(map)
  end

  @doc false
  def normalize_option_map(nil), do: nil
  def normalize_option_map(value) when is_map(value), do: stringify_keys(value)
  def normalize_option_map(value), do: value

  @doc false
  def normalize_option_list(nil), do: nil
  def normalize_option_list(values) when is_list(values), do: Enum.map(values, &normalize_value/1)

  @doc false
  def normalize_value(value), do: BeamWeaver.MapShape.normalize_value(value)

  # Whether a string is longer than `max` characters as provider APIs count
  # them (a JSON Schema `maxLength`): in code points, not bytes or graphemes.
  @doc false
  def longer_than?(string, max) when is_binary(string) and is_integer(max),
    do: byte_size(string) > max and length(String.codepoints(string)) > max
end
