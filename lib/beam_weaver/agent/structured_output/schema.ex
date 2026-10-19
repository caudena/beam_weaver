defmodule BeamWeaver.Agent.StructuredOutput.Schema do
  @moduledoc false

  alias BeamWeaver.Agent.StructuredOutput.SchemaSpec

  @spec schema_specs(term()) :: [SchemaSpec.t()]
  def schema_specs(%{"oneOf" => variants}), do: variant_specs(variants)
  def schema_specs(%{oneOf: variants}), do: variant_specs(variants)
  def schema_specs(schema), do: [schema_spec(schema)]

  defp variant_specs(variants), do: Enum.with_index(variants, &variant_spec/2)

  defp variant_spec(variant, index) when is_map(variant) do
    case Map.get(variant, :title) || Map.get(variant, "title") do
      nil -> schema_spec(variant, name: "response_format_#{index}")
      _title -> schema_spec(variant)
    end
  end

  defp variant_spec(variant, _index), do: schema_spec(variant)

  @spec schema_spec(term(), keyword()) :: SchemaSpec.t()
  def schema_spec(schema, opts \\ [])

  def schema_spec(schema, opts) when is_map(schema) do
    name =
      Keyword.get(opts, :name) || Map.get(schema, :title) || Map.get(schema, "title") ||
        "response_format"

    description =
      Keyword.get(opts, :description) || Map.get(schema, :description) ||
        Map.get(schema, "description") || ""

    %SchemaSpec{
      schema: schema,
      name: to_string(name),
      description: description,
      json_schema: schema,
      strict: Keyword.get(opts, :strict)
    }
  end

  def schema_spec(module, opts) when is_atom(module) do
    name = module |> Module.split() |> List.last()

    case BeamWeaver.Schema.module_schema(module) do
      nil -> schema_spec(%{"title" => name, "type" => "object"}, opts)
      schema -> schema_spec(schema, Keyword.put_new(opts, :name, name))
    end
  end

  def nonempty_description(description) when is_binary(description) and description != "",
    do: description

  def nonempty_description(_description), do: "Return structured response"
end
