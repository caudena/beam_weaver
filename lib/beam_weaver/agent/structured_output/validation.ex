defmodule BeamWeaver.Agent.StructuredOutput.Validation do
  @moduledoc false

  alias BeamWeaver.Agent.StructuredOutput.SchemaSpec
  alias BeamWeaver.Core.Error

  @spec parse(SchemaSpec.t(), map()) :: {:ok, term()} | {:error, Error.t()}
  def parse(%SchemaSpec{} = spec, data) when is_map(data) do
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

    Enum.reduce_while(properties, :ok, fn {key, property}, :ok ->
      case fetch_key(data, key) do
        {:ok, value} ->
          type = BeamWeaver.MapAccess.get(property, :type)

          if valid_json_type?(value, type) do
            {:cont, :ok}
          else
            {:halt,
             {:error,
              Error.new(
                :structured_output_validation_error,
                "structured response field has invalid type",
                %{
                  schema: spec.name,
                  key: key,
                  expected: type,
                  actual: inspect(value)
                }
              )}}
          end

        :error ->
          {:cont, :ok}
      end
    end)
  end

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
