defmodule BeamWeaver.Core.Tool.Schema do
  @moduledoc false

  alias BeamWeaver.Core.Error

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
    with :ok <- validate_required(schema, input) do
      validate_properties(schema, input)
    end
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

  @spec has_key?(map(), term()) :: boolean()
  def has_key?(input, key) when is_atom(key),
    do: Map.has_key?(input, key) or Map.has_key?(input, Atom.to_string(key))

  def has_key?(input, key) when is_binary(key),
    do: Map.has_key?(input, key) or Enum.any?(Map.keys(input), &(to_string(&1) == key))

  def has_key?(input, key), do: Map.has_key?(input, key)

  @spec fetch_key(map(), term()) :: {:ok, term()} | :error
  def fetch_key(input, key) when is_atom(key) do
    cond do
      Map.has_key?(input, key) -> {:ok, Map.fetch!(input, key)}
      Map.has_key?(input, Atom.to_string(key)) -> {:ok, Map.fetch!(input, Atom.to_string(key))}
      true -> :error
    end
  end

  def fetch_key(input, key) when is_binary(key) do
    cond do
      Map.has_key?(input, key) ->
        {:ok, Map.fetch!(input, key)}

      matching_key = Enum.find(Map.keys(input), &(to_string(&1) == key)) ->
        {:ok, Map.fetch!(input, matching_key)}

      true ->
        :error
    end
  end

  def fetch_key(input, key) do
    if Map.has_key?(input, key), do: {:ok, Map.fetch!(input, key)}, else: :error
  end

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

  defp validate_properties(schema, input) do
    schema
    |> schema_value(:properties, %{})
    |> case do
      {_key, properties} when is_map(properties) ->
        Enum.reduce_while(properties, :ok, fn {key, spec}, :ok ->
          case fetch_key(input, key) do
            {:ok, value} ->
              case validate_property(key, value, spec) do
                :ok -> {:cont, :ok}
                {:error, %Error{} = error} -> {:halt, {:error, error}}
              end

            :error ->
              {:cont, :ok}
          end
        end)

      _other ->
        :ok
    end
  end

  defp validate_property(key, value, spec) when is_map(spec) do
    with :ok <- validate_enum(key, value, schema_value(spec, :enum)),
         :ok <- validate_schema_type(key, value, spec) do
      validate_nested_schema(key, value, spec)
    end
  end

  defp validate_property(_key, _value, _spec), do: :ok

  defp validate_enum(_key, _value, nil), do: :ok

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

  defp validate_nested_schema(key, value, spec) do
    cond do
      object_schema?(spec) and is_map(value) ->
        validate_nested_object(key, value, spec)

      array_schema?(spec) and is_list(value) ->
        validate_nested_array(key, value, spec)

      true ->
        :ok
    end
  end

  defp object_schema?(spec) do
    case schema_value(spec, :type) do
      {_key, type} when type in [:object, "object"] -> true
      _other -> false
    end
  end

  defp array_schema?(spec) do
    case schema_value(spec, :type) do
      {_key, type} when type in [:array, "array"] -> true
      _other -> false
    end
  end

  defp validate_nested_object(parent_key, value, spec) do
    with :ok <- validate_required(spec, value) do
      case validate_properties(spec, value) do
        :ok ->
          :ok

        {:error, %Error{} = error} ->
          {:error, put_nested_path(error, parent_key)}
      end
    end
  end

  defp validate_nested_array(parent_key, value, spec) do
    case schema_value(spec, :items) do
      {_items_key, item_schema} when is_map(item_schema) ->
        value
        |> Enum.with_index()
        |> Enum.reduce_while(:ok, fn {item, index}, :ok ->
          case validate_property("#{parent_key}[#{index}]", item, item_schema) do
            :ok -> {:cont, :ok}
            {:error, %Error{} = error} -> {:halt, {:error, error}}
          end
        end)

      _other ->
        :ok
    end
  end

  defp put_nested_path(%Error{} = error, parent_key) do
    details = Map.update(error.details, :path, [parent_key], &[parent_key | List.wrap(&1)])
    %{error | details: details}
  end

  defp validate_type(_key, _value, nil), do: :ok

  defp validate_type(key, value, types) when is_list(types) do
    if Enum.any?(types, &(validate_type(key, value, &1) == :ok)) do
      :ok
    else
      {:error, type_error(key, value, types)}
    end
  end

  defp validate_type(key, value, type) do
    if valid_json_type?(value, type), do: :ok, else: {:error, type_error(key, value, type)}
  end

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
  defp valid_json_type?(_value, _unknown), do: true

  defp type_error(key, value, expected) do
    Error.new(:invalid_input, "tool input has invalid type", %{
      key: key,
      expected: expected,
      actual: inspect(value)
    })
  end

  defp put_default(input, key, default) when is_atom(key) do
    if has_key?(input, key), do: input, else: Map.put(input, key, default)
  end

  defp put_default(input, key, default) when is_binary(key) do
    if has_key?(input, key), do: input, else: Map.put(input, key, default)
  end

  defp put_default(input, key, default) do
    if Map.has_key?(input, key), do: input, else: Map.put(input, key, default)
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

  defp schema_value(schema, key, default \\ nil)

  defp schema_value(schema, key, default) when is_map(schema) do
    cond do
      Map.has_key?(schema, key) -> {key, Map.fetch!(schema, key)}
      Map.has_key?(schema, to_string(key)) -> {to_string(key), Map.fetch!(schema, to_string(key))}
      true -> default
    end
  end

  defp schema_value(_schema, _key, default), do: default
end
