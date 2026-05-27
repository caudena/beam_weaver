defmodule BeamWeaver.Agent.StructuredOutput.Schema do
  @moduledoc false

  alias BeamWeaver.Agent.StructuredOutput.SchemaSpec

  @spec schema_specs(term()) :: [SchemaSpec.t()]
  def schema_specs(%{"oneOf" => variants}), do: Enum.map(variants, &schema_spec/1)
  def schema_specs(%{oneOf: variants}), do: Enum.map(variants, &schema_spec/1)
  def schema_specs(schema), do: [schema_spec(schema)]

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
    cond do
      function_exported?(module, :json_schema, 0) ->
        schema_spec(
          module.json_schema(),
          Keyword.put_new(opts, :name, module |> Module.split() |> List.last())
        )

      function_exported?(module, :schema, 0) ->
        schema_spec(
          module.schema(),
          Keyword.put_new(opts, :name, module |> Module.split() |> List.last())
        )

      true ->
        schema_spec(
          %{"title" => module |> Module.split() |> List.last(), "type" => "object"},
          opts
        )
    end
  end

  def provider_supported?(model, _tools) do
    profile =
      if is_map(model), do: BeamWeaver.MapAccess.get(model, :profile), else: nil

    cond do
      is_map(model) and Map.get(model, :supports_structured_output) ->
        true

      is_map(profile) and BeamWeaver.MapAccess.get(profile, :structured_output) ->
        true

      true ->
        false
    end
  end

  def nonempty_description(description) when is_binary(description) and description != "",
    do: description

  def nonempty_description(_description), do: "Return structured response"
end
