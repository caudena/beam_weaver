defmodule BeamWeaver.OutputParser.Schema do
  @moduledoc false

  alias BeamWeaver.Core.Error

  @spec validate(map(), term()) :: :ok | {:error, Error.t()}
  def validate(schema, data) when is_map(schema) and is_map(data) do
    with :ok <- validate_required(schema, data) do
      validate_properties(schema, data)
    end
  end

  def validate(_schema, _data),
    do: parser_error(:schema_parser, "schema parser expected an object")

  def cast(data, nil), do: {:ok, data}

  def cast(data, module) when is_atom(module) do
    cond do
      function_exported?(module, :new, 1) ->
        module.new(data)

      function_exported?(module, :struct, 1) ->
        {:ok, struct(module, atomize_existing_keys(data))}

      function_exported?(module, :__struct__, 0) ->
        {:ok, struct(module, atomize_existing_keys(data))}

      true ->
        {:ok, data}
    end
  rescue
    exception ->
      parser_error(:schema_parser, "parsed output could not be cast", %{
        reason: Exception.message(exception)
      })
  end

  def cast(data, _as), do: {:ok, data}

  def fetch_key(map, key) do
    Enum.find_value(map, :error, fn {candidate, value} ->
      if to_string(candidate) == to_string(key), do: {:ok, value}, else: nil
    end)
  end

  def normalize_module_schema(module) when is_atom(module) do
    cond do
      function_exported?(module, :json_schema, 0) -> module.json_schema()
      function_exported?(module, :schema, 0) -> module.schema()
      true -> nil
    end
  end

  def normalize_module_schema(schema) when is_map(schema), do: schema
  def normalize_module_schema(_schema), do: nil

  defp validate_required(schema, data) do
    required = BeamWeaver.MapAccess.get(schema, :required, [])
    missing = Enum.reject(required, &has_key?(data, &1))

    if missing == [] do
      :ok
    else
      parser_error(:schema_parser, "parsed output is missing required keys", %{missing: missing})
    end
  end

  defp validate_properties(schema, data) do
    properties = BeamWeaver.MapAccess.get(schema, :properties, %{})

    Enum.reduce_while(properties, :ok, fn {key, spec}, :ok ->
      with {:ok, value} <- fetch_key(data, key),
           :ok <- validate_property_type(key, value, spec) do
        {:cont, :ok}
      else
        :error -> {:cont, :ok}
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp validate_property_type(key, value, spec) when is_map(spec) do
    with :ok <- validate_property_enum(key, value, spec) do
      case BeamWeaver.MapAccess.get(spec, :type) do
        nil ->
          :ok

        type ->
          if valid_type?(value, type) do
            :ok
          else
            parser_error(:schema_parser, "parsed output field has invalid type", %{
              key: key,
              expected: type,
              actual: inspect(value)
            })
          end
      end
    end
  end

  defp validate_property_enum(key, value, spec) do
    case BeamWeaver.MapAccess.get(spec, :enum) do
      enum when is_list(enum) ->
        if value in enum do
          :ok
        else
          parser_error(:schema_parser, "parsed output field is not in enum", %{
            key: key,
            expected: enum,
            actual: value
          })
        end

      _other ->
        :ok
    end
  end

  defp valid_type?(value, "string"), do: is_binary(value)
  defp valid_type?(value, :string), do: is_binary(value)
  defp valid_type?(value, "integer"), do: is_integer(value)
  defp valid_type?(value, :integer), do: is_integer(value)
  defp valid_type?(value, "number"), do: is_number(value)
  defp valid_type?(value, :number), do: is_number(value)
  defp valid_type?(value, "boolean"), do: is_boolean(value)
  defp valid_type?(value, :boolean), do: is_boolean(value)
  defp valid_type?(value, "object"), do: is_map(value)
  defp valid_type?(value, :object), do: is_map(value)
  defp valid_type?(value, "array"), do: is_list(value)
  defp valid_type?(value, :array), do: is_list(value)
  defp valid_type?(nil, "null"), do: true
  defp valid_type?(nil, :null), do: true
  defp valid_type?(_value, _type), do: true

  defp has_key?(map, key) when is_binary(key),
    do: Map.has_key?(map, key) or Enum.any?(Map.keys(map), &(to_string(&1) == key))

  defp has_key?(map, key) when is_atom(key),
    do: Map.has_key?(map, key) or Map.has_key?(map, Atom.to_string(key))

  defp atomize_existing_keys(map) do
    Map.new(map, fn {key, value} ->
      try do
        {String.to_existing_atom(to_string(key)), value}
      rescue
        ArgumentError -> {key, value}
      end
    end)
  end

  defp parser_error(parser, message, details \\ %{}) do
    {:error, Error.new(:output_parser_error, message, Map.put(details, :parser, parser))}
  end
end
