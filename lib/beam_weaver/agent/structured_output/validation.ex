defmodule BeamWeaver.Agent.StructuredOutput.Validation do
  @moduledoc false

  alias BeamWeaver.Agent.StructuredOutput.SchemaSpec
  alias BeamWeaver.Core.Error

  import BeamWeaver.Core.Tool.Schema, only: [valid_json_type?: 2]

  @spec parse(SchemaSpec.t(), map()) :: {:ok, term()} | {:error, Error.t()}
  def parse(%SchemaSpec{} = spec, data) when is_map(data) do
    # Strict provider schemas render optional properties as nullable, so a
    # model answers "no value" with null; the parsed response carries the
    # property as absent, as it would have been without strict rendering.
    data = drop_null_optionals(spec.json_schema, data)

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
  def validate_data(%SchemaSpec{} = spec, data) when is_map(data) do
    required = BeamWeaver.MapAccess.get(spec.json_schema, :required, [])
    missing = Enum.reject(required, &BeamWeaver.MapAccess.has_key?(data, &1))

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
      case BeamWeaver.MapAccess.fetch(data, key) do
        # A null is fine when the property's type allows it (an explicitly
        # nullable field such as `"type": ["object", "null"]`) or when the
        # property is optional, the nullable rendering of "absent". Only a
        # required property whose type excludes null fails.
        {:ok, value} ->
          cond do
            valid_json_type?(value, BeamWeaver.MapAccess.get(property, :type)) -> {:cont, :ok}
            is_nil(value) and to_string(key) not in required -> {:cont, :ok}
            true -> invalid_type(spec, key, property, value)
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

  # Walks the schema alongside the data: nullable optionals appear at any depth
  # (objects nested in objects or in array items), and each is dropped where its
  # own object schema does not require it.
  defp drop_null_optionals(schema, data) when is_map(schema) and is_map(data) do
    required = schema |> BeamWeaver.MapAccess.get(:required, []) |> Enum.map(&to_string/1)
    properties = BeamWeaver.MapAccess.get(schema, :properties, %{})

    for {key, value} <- data, not is_nil(value) or to_string(key) in required, into: %{} do
      case property_schema(properties, key) do
        nil -> {key, value}
        property -> {key, drop_null_optionals(property, value)}
      end
    end
  end

  defp drop_null_optionals(schema, data) when is_map(schema) and is_list(data) do
    case BeamWeaver.MapAccess.get(schema, :items) do
      items when is_map(items) -> Enum.map(data, &drop_null_optionals(items, &1))
      _other -> data
    end
  end

  defp drop_null_optionals(_schema, data), do: data

  defp property_schema(properties, key) when is_map(properties) do
    case BeamWeaver.MapAccess.fetch(properties, key) do
      {:ok, property} when is_map(property) -> property
      _other -> nil
    end
  end

  defp property_schema(_properties, _key), do: nil
end
