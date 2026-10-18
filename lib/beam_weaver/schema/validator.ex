defmodule BeamWeaver.Schema.Validator do
  @moduledoc false

  # Checks a decoded JSON object against a JSON Schema's top level: its
  # required keys, and the type and enum of each property it has. Keys match
  # as strings, so the schema and the object may use atoms or strings.

  alias BeamWeaver.Core.Error

  @spec validate(map(), term()) :: :ok | {:error, Error.t()}
  def validate(schema, data) when is_map(schema) and is_map(data) do
    with :ok <- validate_required(schema, data) do
      validate_properties(schema, data)
    end
  end

  def validate(_schema, _data), do: error("parsed output must be an object")

  defp validate_required(schema, data) do
    required = BeamWeaver.MapAccess.get(schema, :required, [])
    missing = Enum.reject(required, &has_key?(data, &1))

    if missing == [],
      do: :ok,
      else: error("parsed output is missing required keys", %{missing: missing})
  end

  defp validate_properties(schema, data) do
    properties = BeamWeaver.MapAccess.get(schema, :properties, %{})

    Enum.reduce_while(properties, :ok, fn {key, spec}, :ok ->
      with {:ok, value} <- fetch_key(data, key),
           :ok <- validate_property(key, value, spec) do
        {:cont, :ok}
      else
        :error -> {:cont, :ok}
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp validate_property(key, value, spec) when is_map(spec) do
    with :ok <- validate_enum(key, value, spec) do
      type = BeamWeaver.MapAccess.get(spec, :type)

      if is_nil(type) or valid_type?(value, type),
        do: :ok,
        else: error("parsed output field has invalid type", %{key: key, expected: type, actual: inspect(value)})
    end
  end

  defp validate_enum(key, value, spec) do
    case BeamWeaver.MapAccess.get(spec, :enum) do
      enum when is_list(enum) ->
        if value in enum,
          do: :ok,
          else: error("parsed output field is not in enum", %{key: key, expected: enum, actual: value})

      _other ->
        :ok
    end
  end

  # A type not checked here, such as `null` or a list of types, passes.
  defp valid_type?(value, type) when is_atom(type), do: valid_type?(value, Atom.to_string(type))
  defp valid_type?(value, "string"), do: is_binary(value)
  defp valid_type?(value, "integer"), do: is_integer(value)
  defp valid_type?(value, "number"), do: is_number(value)
  defp valid_type?(value, "boolean"), do: is_boolean(value)
  defp valid_type?(value, "object"), do: is_map(value)
  defp valid_type?(value, "array"), do: is_list(value)
  defp valid_type?(_value, _type), do: true

  defp fetch_key(map, key) do
    Enum.find_value(map, :error, fn {candidate, value} ->
      if to_string(candidate) == to_string(key), do: {:ok, value}
    end)
  end

  defp has_key?(map, key) when is_binary(key),
    do: Map.has_key?(map, key) or Enum.any?(Map.keys(map), &(to_string(&1) == key))

  defp has_key?(map, key) when is_atom(key),
    do: Map.has_key?(map, key) or Map.has_key?(map, Atom.to_string(key))

  defp error(message, details \\ %{}), do: {:error, Error.new(:schema_validation_error, message, details)}
end
