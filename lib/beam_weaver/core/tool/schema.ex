defmodule BeamWeaver.Core.Tool.Schema do
  @moduledoc false

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Result

  @spec public_input(map(), [atom() | String.t()]) :: map()
  def public_input(schema, []), do: schema

  def public_input(schema, injected_keys) when is_map(schema) do
    injected_names = MapSet.new(Enum.map(injected_keys, &to_string/1))

    schema
    |> remove_injected_properties(injected_names)
    |> remove_injected_required(injected_names)
  end

  @spec properties(map()) :: map()
  def properties(schema) when is_map(schema) do
    case schema_value(schema, :properties) do
      {_key, properties} when is_map(properties) -> properties
      _other -> %{}
    end
  end

  def properties(_schema), do: %{}

  @spec validate(map(), map()) :: :ok | {:error, Error.t()}
  def validate(schema, input) when is_map(schema) and is_map(input) do
    with {:ok, _normalized} <- normalize(schema, input), do: :ok
  end

  @doc false
  @spec normalize(map(), map()) :: {:ok, map()} | {:error, Error.t()}
  def normalize(schema, input) when is_map(schema) and is_map(input) do
    with {:ok, normalized} <- normalize_keys(input),
         :ok <- validate_required(schema, normalized),
         :ok <- validate_additional_properties(schema, normalized) do
      normalize_properties(schema, normalized)
    end
  end

  @doc false
  # Validates any value against `schema`, as a property's value is: an object
  # comes back with string keys. An error about the value itself names no key.
  @spec normalize_value(map(), term()) :: {:ok, term()} | {:error, Error.t()}
  def normalize_value(schema, value) when is_map(schema) do
    with {:ok, value} <- normalize_property(nil, value, schema),
         {:ok, value} <- normalize_untyped_object(schema, value) do
      {:ok, value}
    else
      {:error, %Error{details: %{key: nil} = details} = error} ->
        {:error, %{error | details: Map.delete(details, :key)}}

      {:error, %Error{}} = error ->
        error
    end
  end

  # A schema without a type still describes an object's keys.
  defp normalize_untyped_object(schema, value) do
    if is_map(value) and not is_struct(value) and is_nil(schema_value(schema, :type)),
      do: normalize(schema, value),
      else: {:ok, value}
  end

  @spec apply_defaults(map(), map()) :: map()
  def apply_defaults(input, schema) do
    schema
    |> properties()
    |> Enum.reduce(input, fn {key, spec}, acc ->
      case schema_value(spec, :default) do
        {_default_key, default} -> put_default(acc, key, default)
        nil -> acc
      end
    end)
  end

  defp has_key?(input, key) when is_atom(key),
    do: Map.has_key?(input, key) or Map.has_key?(input, Atom.to_string(key))

  defp has_key?(input, key) when is_binary(key),
    do: Map.has_key?(input, key) or Enum.any?(Map.keys(input), &(to_string(&1) == key))

  defp has_key?(input, key), do: Map.has_key?(input, key)

  defp validate_required(schema, input) do
    required = BeamWeaver.MapAccess.get(schema, :required, [])
    missing = Enum.reject(required, &has_key?(input, &1))

    case missing do
      [] ->
        :ok

      missing ->
        {:error, Error.new(:invalid_input, "tool input is missing required keys", %{missing: missing})}
    end
  end

  defp normalize_properties(schema, input) do
    schema
    |> schema_value(:properties)
    |> case do
      {_key, properties} when is_map(properties) ->
        Enum.reduce_while(properties, {:ok, input}, fn {schema_key, spec}, {:ok, normalized} ->
          key = to_string(schema_key)

          case Map.fetch(normalized, key) do
            {:ok, value} ->
              case normalize_property(schema_key, value, spec) do
                {:ok, value} -> {:cont, {:ok, Map.put(normalized, key, value)}}
                {:error, %Error{} = error} -> {:halt, {:error, error}}
              end

            :error ->
              {:cont, {:ok, normalized}}
          end
        end)

      _other ->
        {:ok, input}
    end
  end

  defp normalize_property(key, value, spec) when is_map(spec) do
    with :ok <- validate_enum(key, value, schema_value(spec, :enum)),
         :ok <- validate_schema_type(key, value, spec),
         :ok <- validate_bounds(key, value, spec) do
      normalize_nested_schema(key, value, spec)
    end
  end

  defp normalize_property(_key, value, _spec), do: {:ok, value}

  defp validate_enum(key, value, {_enum_key, values}) when is_list(values) do
    if Enum.any?(values, &(&1 == value)) do
      :ok
    else
      {:error, Error.new(:invalid_input, "tool input is not in enum", %{key: key, allowed: values})}
    end
  end

  defp validate_enum(_key, _value, _enum), do: :ok

  defp validate_schema_type(key, value, spec) do
    case schema_value(spec, :type) do
      {_type_key, type} -> validate_type(key, value, type)
      nil -> :ok
    end
  end

  defp normalize_nested_schema(key, value, spec) do
    case schema_value(spec, :type) do
      {_type_key, type} when type in [:object, "object"] and is_map(value) ->
        with {:error, %Error{} = error} <- normalize(spec, value), do: {:error, put_nested_path(error, key)}

      {_type_key, type} when type in [:array, "array"] and is_list(value) ->
        normalize_nested_array(key, value, spec)

      _other ->
        {:ok, value}
    end
  end

  defp normalize_nested_array(parent_key, value, spec) do
    case schema_value(spec, :items) do
      {_items_key, item_schema} when is_map(item_schema) ->
        value
        |> Enum.with_index()
        |> Result.traverse(fn {item, index} -> normalize_property("#{parent_key}[#{index}]", item, item_schema) end)

      _other ->
        {:ok, value}
    end
  end

  defp validate_additional_properties(schema, input) do
    case schema_value(schema, :additionalProperties) do
      {_key, false} ->
        allowed = schema |> properties() |> Map.keys() |> MapSet.new(&to_string/1)
        unknown = Enum.reject(Map.keys(input), &MapSet.member?(allowed, &1))

        if unknown == [] do
          :ok
        else
          {:error, Error.new(:invalid_input, "tool input contains unknown keys", %{unknown: unknown})}
        end

      _other ->
        :ok
    end
  end

  defp validate_bounds(key, value, spec) do
    with :ok <- validate_string_bounds(key, value, spec),
         :ok <- validate_number_bounds(key, value, spec) do
      validate_collection_bounds(key, value, spec)
    end
  end

  defp validate_string_bounds(key, value, spec) when is_binary(value) do
    if String.valid?(value) do
      length = String.length(value)

      with :ok <- minimum_bound(key, length, schema_value(spec, :minLength), "string is too short") do
        maximum_bound(key, length, schema_value(spec, :maxLength), "string is too long")
      end
    else
      {:error, Error.new(:invalid_input, "tool input string is not valid UTF-8", %{key: key})}
    end
  end

  defp validate_string_bounds(_key, _value, _spec), do: :ok

  defp validate_number_bounds(key, value, spec) when is_number(value) do
    with :ok <- minimum_bound(key, value, schema_value(spec, :minimum), "number is too small") do
      maximum_bound(key, value, schema_value(spec, :maximum), "number is too large")
    end
  end

  defp validate_number_bounds(_key, _value, _spec), do: :ok

  defp validate_collection_bounds(key, value, spec) when is_list(value) do
    with :ok <- minimum_bound(key, length(value), schema_value(spec, :minItems), "array is too short") do
      maximum_bound(key, length(value), schema_value(spec, :maxItems), "array is too long")
    end
  end

  defp validate_collection_bounds(_key, _value, _spec), do: :ok

  defp minimum_bound(key, value, {_schema_key, minimum}, message) when is_number(minimum) do
    if value >= minimum,
      do: :ok,
      else: {:error, Error.new(:invalid_input, message, %{key: key, minimum: minimum})}
  end

  defp minimum_bound(_key, _value, _bound, _message), do: :ok

  defp maximum_bound(key, value, {_schema_key, maximum}, message) when is_number(maximum) do
    if value <= maximum,
      do: :ok,
      else: {:error, Error.new(:invalid_input, message, %{key: key, maximum: maximum})}
  end

  defp maximum_bound(_key, _value, _bound, _message), do: :ok

  defp normalize_keys(input) do
    Enum.reduce_while(input, {:ok, %{}}, fn
      {key, value}, {:ok, normalized} when is_atom(key) or is_binary(key) ->
        key = to_string(key)

        if Map.has_key?(normalized, key) do
          {:halt, {:error, Error.new(:invalid_input, "tool input contains colliding keys", %{key: key})}}
        else
          {:cont, {:ok, Map.put(normalized, key, value)}}
        end

      {key, _value}, _acc ->
        {:halt,
         {:error,
          Error.new(:invalid_input, "tool input key must be a string or atom", %{
            key: inspect(key)
          })}}
    end)
  end

  defp put_nested_path(%Error{} = error, nil), do: error

  defp put_nested_path(%Error{} = error, parent_key) do
    details = Map.update(error.details, :path, [parent_key], &[parent_key | List.wrap(&1)])
    %{error | details: details}
  end

  defp validate_type(key, value, type) do
    if valid_json_type?(value, type), do: :ok, else: {:error, type_error(key, value, type)}
  end

  def valid_json_type?(value, type) when is_atom(type), do: valid_json_type?(value, Atom.to_string(type))
  def valid_json_type?(value, "string"), do: is_binary(value)
  def valid_json_type?(value, "integer"), do: is_integer(value)
  def valid_json_type?(value, "number"), do: is_number(value)
  def valid_json_type?(value, "boolean"), do: is_boolean(value)
  def valid_json_type?(value, "object"), do: is_map(value) and not is_struct(value)
  def valid_json_type?(value, "array"), do: is_list(value)
  def valid_json_type?(value, "null"), do: is_nil(value)
  def valid_json_type?(value, types) when is_list(types), do: Enum.any?(types, &valid_json_type?(value, &1))
  def valid_json_type?(_value, _other), do: true

  defp type_error(key, value, expected) do
    Error.new(:invalid_input, "tool input has invalid type", %{
      key: key,
      expected: expected,
      actual: inspect(value)
    })
  end

  defp put_default(input, key, default) do
    if has_key?(input, key), do: input, else: Map.put(input, key, default)
  end

  defp remove_injected_properties(schema, injected_names) do
    case schema_value(schema, :properties) do
      {key, properties} when is_map(properties) ->
        properties =
          Map.reject(properties, fn {property, _schema} ->
            MapSet.member?(injected_names, to_string(property))
          end)

        Map.put(schema, key, properties)

      _other ->
        schema
    end
  end

  defp remove_injected_required(schema, injected_names) do
    case schema_value(schema, :required) do
      {key, required} when is_list(required) ->
        required =
          Enum.reject(required, fn field ->
            MapSet.member?(injected_names, to_string(field))
          end)

        Map.put(schema, key, required)

      _other ->
        schema
    end
  end

  defp schema_value(schema, key) when is_map(schema) do
    cond do
      Map.has_key?(schema, key) -> {key, Map.fetch!(schema, key)}
      Map.has_key?(schema, to_string(key)) -> {to_string(key), Map.fetch!(schema, to_string(key))}
      true -> nil
    end
  end

  defp schema_value(_schema, _key), do: nil
end
