defmodule BeamWeaver.Agent.StructuredOutput.Validation do
  @moduledoc false

  alias BeamWeaver.Agent.StructuredOutput.SchemaSpec
  alias BeamWeaver.Core.Error

  @spec parse(SchemaSpec.t(), map()) :: {:ok, term()} | {:error, Error.t()}
  def parse(%SchemaSpec{} = spec, data) when is_map(data) do
    # Strict provider schemas render optional properties as nullable, so a
    # model answers "no value" with null; the parsed response carries the
    # property as absent, as it would have been without strict rendering.
    data = drop_null_optionals(spec, data)

    with :ok <- validate_data(spec, data) do
      {:ok, data}
    end
  end

  def parse(%SchemaSpec{} = spec, data) do
    {:error,
     Error.new(:structured_output_validation_error, "structured response must be an object", %{
       schema: spec.name,
       data: inspect(data)
     })}
  end

  @spec validate_data(SchemaSpec.t(), map()) :: :ok | {:error, Error.t()}
  def validate_data(%SchemaSpec{} = spec, data) do
    required = BeamWeaver.MapAccess.get(spec.json_schema, :required, [])
    missing = Enum.reject(required, &has_key?(data, &1))

    if missing == [] do
      validate_properties(spec, data)
    else
      {:error,
       Error.new(
         :structured_output_validation_error,
         "structured response is missing required keys",
         %{
           schema: spec.name,
           missing: missing
         }
       )}
    end
  end

  defp validate_properties(spec, data) do
    properties = BeamWeaver.MapAccess.get(spec.json_schema, :properties, %{})
    required = spec.json_schema |> BeamWeaver.MapAccess.get(:required, []) |> Enum.map(&to_string/1)

    Enum.reduce_while(properties, :ok, fn {key, property}, :ok ->
      case fetch_key(data, key) do
        # A null is fine when the property's type allows it (an explicitly
        # nullable field such as `"type": ["object", "null"]`) or when the
        # property is optional, the nullable rendering of "absent". Only a
        # required property whose type excludes null fails.
        {:ok, nil} ->
          type = BeamWeaver.MapAccess.get(property, :type)

          cond do
            valid_json_type?(nil, type) -> {:cont, :ok}
            to_string(key) in required -> invalid_type(spec, key, property, nil)
            true -> {:cont, :ok}
          end

        {:ok, value} ->
          type = BeamWeaver.MapAccess.get(property, :type)

          if valid_json_type?(value, type) do
            {:cont, :ok}
          else
            invalid_type(spec, key, property, value)
          end

        :error ->
          {:cont, :ok}
      end
    end)
  end

  defp invalid_type(spec, key, property, value) do
    {:halt,
     {:error,
      Error.new(
        :structured_output_validation_error,
        "structured response field has invalid type",
        %{
          schema: spec.name,
          key: key,
          expected: BeamWeaver.MapAccess.get(property, :type),
          actual: inspect(value)
        }
      )}}
  end

  defp drop_null_optionals(%SchemaSpec{} = spec, data), do: drop_null_optionals_in(spec.json_schema, data)

  # Walks the schema alongside the data: nullable optionals appear at any depth
  # (objects nested in objects or in array items), and each is dropped where its
  # own object schema does not require it.
  defp drop_null_optionals_in(schema, data) when is_map(schema) and is_map(data) do
    required = schema |> BeamWeaver.MapAccess.get(:required, []) |> Enum.map(&to_string/1)
    properties = BeamWeaver.MapAccess.get(schema, :properties, %{})

    data
    |> Enum.reject(fn {key, value} -> is_nil(value) and to_string(key) not in required end)
    |> Enum.map(fn {key, value} ->
      case property_schema(properties, key) do
        nil -> {key, value}
        property -> {key, drop_null_optionals_in(property, value)}
      end
    end)
    |> Map.new()
  end

  defp drop_null_optionals_in(schema, data) when is_map(schema) and is_list(data) do
    case BeamWeaver.MapAccess.get(schema, :items) do
      items when is_map(items) -> Enum.map(data, &drop_null_optionals_in(items, &1))
      _other -> data
    end
  end

  defp drop_null_optionals_in(_schema, data), do: data

  defp property_schema(properties, key) when is_map(properties) do
    case fetch_key(properties, key) do
      {:ok, property} when is_map(property) -> property
      _other -> nil
    end
  end

  defp property_schema(_properties, _key), do: nil

  defp has_key?(map, key) when is_atom(key),
    do: Map.has_key?(map, key) or Map.has_key?(map, Atom.to_string(key))

  defp has_key?(map, key) when is_binary(key),
    do: Map.has_key?(map, key) or Enum.any?(Map.keys(map), &(to_string(&1) == key))

  defp fetch_key(map, key) when is_atom(key) do
    cond do
      Map.has_key?(map, key) -> {:ok, Map.fetch!(map, key)}
      Map.has_key?(map, Atom.to_string(key)) -> {:ok, Map.fetch!(map, Atom.to_string(key))}
      true -> :error
    end
  end

  defp fetch_key(map, key) when is_binary(key) do
    cond do
      Map.has_key?(map, key) ->
        {:ok, Map.fetch!(map, key)}

      Enum.any?(Map.keys(map), &(to_string(&1) == key)) ->
        {:ok, map[Enum.find(Map.keys(map), &(to_string(&1) == key))]}

      true ->
        :error
    end
  end

  defp valid_json_type?(_value, nil), do: true
  defp valid_json_type?(value, "string"), do: is_binary(value)
  defp valid_json_type?(value, :string), do: is_binary(value)
  defp valid_json_type?(value, "integer"), do: is_integer(value)
  defp valid_json_type?(value, :integer), do: is_integer(value)
  defp valid_json_type?(value, "number"), do: is_number(value)
  defp valid_json_type?(value, :number), do: is_number(value)
  defp valid_json_type?(value, "boolean"), do: is_boolean(value)
  defp valid_json_type?(value, :boolean), do: is_boolean(value)
  defp valid_json_type?(value, "object"), do: is_map(value)
  defp valid_json_type?(value, :object), do: is_map(value)
  defp valid_json_type?(value, "array"), do: is_list(value)
  defp valid_json_type?(value, :array), do: is_list(value)
  defp valid_json_type?(nil, "null"), do: true
  defp valid_json_type?(nil, :null), do: true

  defp valid_json_type?(value, types) when is_list(types),
    do: Enum.any?(types, &valid_json_type?(value, &1))

  defp valid_json_type?(_value, _unknown), do: true
end
