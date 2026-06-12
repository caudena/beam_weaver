defmodule BeamWeaver.Tool.Schema.Fields do
  @moduledoc false

  alias BeamWeaver.Core.Error

  def from_fields(fields) when is_list(fields) do
    {properties, required} =
      fields
      |> Enum.reduce({%{}, []}, fn {name, type, opts}, {properties, required} ->
        schema =
          type
          |> type_schema()
          |> put_description(opts)
          |> put_enum(opts)
          |> put_default(opts)
          |> put_nullable(opts)
          |> put_nested(opts)

        key = normalize_key(name)
        required = if Keyword.get(opts, :required, true), do: required ++ [key], else: required

        {Map.put(properties, key, schema), required}
      end)

    %{
      type: "object",
      properties: properties,
      required: required
    }
  end

  def type_schema(:string), do: %{type: "string"}
  def type_schema(:integer), do: %{type: "integer"}
  def type_schema(:number), do: %{type: "number"}
  def type_schema(:float), do: %{type: "number"}
  def type_schema(:decimal), do: %{type: "number"}
  def type_schema(:boolean), do: %{type: "boolean"}
  def type_schema(:binary), do: %{type: "string"}
  def type_schema(:id), do: %{type: "string"}
  def type_schema(:binary_id), do: %{type: "string"}
  def type_schema(:object), do: %{type: "object"}
  def type_schema(:map), do: %{type: "object"}
  def type_schema(:array), do: %{type: "array"}
  def type_schema(:list), do: %{type: "array"}
  def type_schema(:null), do: %{type: "null"}
  def type_schema(:any), do: %{}
  def type_schema(:date), do: %{type: "string", format: "date"}
  def type_schema(:time), do: %{type: "string", format: "time"}
  def type_schema(:utc_datetime), do: %{type: "string", format: "date-time"}
  def type_schema(:naive_datetime), do: %{type: "string", format: "date-time"}

  def type_schema({:array, item_type}) do
    %{type: "array", items: type_schema(item_type)}
  end

  def type_schema({:union, types}) when is_list(types) do
    %{anyOf: Enum.map(types, &type_schema/1)}
  end

  def type_schema({:object, fields}) when is_list(fields) do
    from_fields(fields)
  end

  def type_schema(schema) when is_map(schema), do: schema
  def type_schema(type) when is_binary(type), do: %{type: type}
  def type_schema(_type), do: %{}

  def normalize_key(key) when is_atom(key), do: key
  def normalize_key(key) when is_binary(key), do: key

  def stringify_schema(map) when is_map(map) do
    BeamWeaver.MapShape.stringify_keys(map)
  end

  def from_nimble_options(opts) when is_list(opts) do
    fields =
      Enum.map(opts, fn
        {name, spec} when is_list(spec) ->
          type = Keyword.get(spec, :type, :any)

          field_opts =
            []
            |> maybe_keyword(
              :description,
              Keyword.get(spec, :doc) || Keyword.get(spec, :description)
            )
            |> maybe_keyword(:required, Keyword.get(spec, :required, false))
            |> maybe_keyword(:default, Keyword.get(spec, :default))
            |> maybe_keyword(:enum, Keyword.get(spec, :values) || Keyword.get(spec, :enum))

          {name, type, field_opts}

        other ->
          throw({:invalid_nimble_option, other})
      end)

    {:ok, from_fields(fields)}
  catch
    {:invalid_nimble_option, invalid} ->
      {:error,
       Error.new(:invalid_tool_schema, "NimbleOptions schema entries must be {name, opts}", %{
         entry: inspect(invalid)
       })}
  end

  def from_ecto_schema(module) when is_atom(module) do
    with true <- Code.ensure_loaded?(module),
         true <- function_exported?(module, :__schema__, 1),
         fields when is_list(fields) <- module.__schema__(:fields) do
      fields =
        Enum.map(fields, fn field ->
          {field, ecto_type(module.__schema__(:type, field)), required: false}
        end)

      {:ok, from_fields(fields)}
    else
      _other ->
        {:error,
         Error.new(:invalid_tool_schema, "module is not an Ecto-style schema", %{
           module: inspect(module)
         })}
    end
  end

  defp ecto_type({:array, type}), do: {:array, ecto_type(type)}
  defp ecto_type(:integer), do: :integer
  defp ecto_type(:id), do: :id
  defp ecto_type(:binary_id), do: :binary_id
  defp ecto_type(:float), do: :float
  defp ecto_type(:decimal), do: :decimal
  defp ecto_type(:boolean), do: :boolean
  defp ecto_type(:map), do: :map
  defp ecto_type(:binary), do: :binary
  defp ecto_type(:utc_datetime), do: :utc_datetime
  defp ecto_type(:naive_datetime), do: :naive_datetime
  defp ecto_type(:date), do: :date
  defp ecto_type(:time), do: :time
  defp ecto_type(_type), do: :string

  defp maybe_keyword(opts, _key, nil), do: opts
  defp maybe_keyword(opts, key, value), do: Keyword.put(opts, key, value)

  defp put_description(schema, opts) do
    case Keyword.get(opts, :description) do
      nil -> schema
      description -> Map.put(schema, :description, description)
    end
  end

  defp put_enum(schema, opts) do
    case Keyword.get(opts, :enum) do
      nil -> schema
      values -> Map.put(schema, :enum, values)
    end
  end

  defp put_default(schema, opts) do
    if Keyword.has_key?(opts, :default),
      do: Map.put(schema, :default, Keyword.fetch!(opts, :default)),
      else: schema
  end

  defp put_nullable(schema, opts) do
    if Keyword.get(opts, :nullable, false) do
      type = BeamWeaver.MapAccess.get(schema, :type)
      Map.put(schema, :type, List.wrap(type) ++ ["null"])
    else
      schema
    end
  end

  defp put_nested(schema, opts) do
    schema
    |> maybe_put(:properties, Keyword.get(opts, :properties))
    |> maybe_put(:items, Keyword.get(opts, :items) && type_schema(Keyword.get(opts, :items)))
  end

  defp maybe_put(schema, _key, nil), do: schema
  defp maybe_put(schema, key, value), do: Map.put(schema, key, value)
end
