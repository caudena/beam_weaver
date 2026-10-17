defmodule BeamWeaver.Tool.Renderer do
  @moduledoc """
  Provider-facing rendering helpers for BeamWeaver tools.
  """

  import BeamWeaver.MapShape, only: [put_present: 3]

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Tool.Schema

  @schema_child_keys ["properties", "items", "anyOf", "oneOf", "allOf", "$defs", "definitions"]
  @provider_name ~r/^[A-Za-z0-9_-]{1,64}$/
  @deepseek_name ~r/^[A-Za-z0-9_-]{1,128}$/

  @doc """
  Renders a readable tool description.
  """
  @spec description(term()) :: String.t()
  def description(tool) do
    "#{Tool.name(tool)}: #{Tool.description(tool)}"
  end

  @doc """
  Renders tool names and descriptions as plain text.
  """
  @spec render_text_description([term()]) :: String.t()
  def render_text_description(tools) when is_list(tools) do
    Enum.map_join(tools, "\n", &"#{Tool.name(&1)} - #{Tool.description(&1)}")
  end

  @doc """
  Renders tool names, descriptions, and public argument schemas as plain text.
  """
  @spec render_text_description_and_args([term()]) :: String.t()
  def render_text_description_and_args(tools) when is_list(tools) do
    Enum.map_join(tools, "\n", fn tool ->
      args = tool |> Tool.args() |> inspect(limit: :infinity)
      "#{Tool.name(tool)} - #{Tool.description(tool)}, args: #{args}"
    end)
  end

  @doc false
  # What a tool adds to a request, for counting its tokens: a map as given,
  # and a tool module or `%Tool{}` struct, which has no JSON form of its own,
  # as its name, description and parameters.
  @spec declaration(term()) :: term()
  def declaration(%{} = tool) when not is_struct(tool), do: tool

  def declaration(tool) do
    %{"name" => Tool.name(tool), "description" => Tool.description(tool), "parameters" => Tool.input_schema(tool)}
  rescue
    _exception -> tool
  end

  @doc """
  Renders an OpenAI function declaration.
  """
  @spec openai_function(term(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def openai_function(tool, opts \\ []) do
    with :ok <- validate_provider_name(Tool.name(tool), Keyword.get(opts, :provider, :openai)),
         {:ok, parameters} <-
           tool
           |> Tool.input_schema()
           |> BeamWeaver.MapShape.stringify_keys()
           |> Schema.dereference_refs() do
      function = %{
        "name" => Tool.name(tool),
        "description" => Tool.description(tool),
        "parameters" => maybe_strict_schema(parameters, Keyword.get(opts, :strict))
      }

      {:ok, put_present(function, "strict", Keyword.get(opts, :strict))}
    end
  end

  @doc """
  Renders an OpenAI Responses tool declaration.
  """
  @spec openai_tool(term(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def openai_tool(tool, opts \\ []) do
    with {:ok, function} <- openai_function(tool, opts) do
      {:ok, Map.put(function, "type", "function")}
    end
  end

  @doc """
  Raises on invalid OpenAI tool rendering.
  """
  @spec openai_tool!(term(), keyword()) :: map()
  def openai_tool!(tool, opts \\ []), do: tool |> openai_tool(opts) |> BeamWeaver.Policy.bang()

  @doc """
  Renders an Anthropic custom tool declaration.
  """
  @spec anthropic_tool(term(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def anthropic_tool(tool, opts \\ []) do
    with :ok <- validate_provider_name(Tool.name(tool), :anthropic),
         {:ok, input_schema} <-
           tool
           |> Tool.input_schema()
           |> BeamWeaver.MapShape.stringify_keys()
           |> Schema.dereference_refs() do
      tool =
        %{
          "name" => Tool.name(tool),
          "description" => Tool.description(tool),
          "input_schema" => maybe_strict_schema(input_schema, Keyword.get(opts, :strict))
        }
        |> put_present("strict", Keyword.get(opts, :strict))
        |> put_present("cache_control", Keyword.get(opts, :cache_control))
        |> put_present("defer_loading", Keyword.get(opts, :defer_loading))
        |> put_present("input_examples", Keyword.get(opts, :input_examples))
        |> put_present("allowed_callers", Keyword.get(opts, :allowed_callers))

      {:ok, tool}
    end
  end

  @doc """
  Raises on invalid Anthropic tool rendering.
  """
  @spec anthropic_tool!(term(), keyword()) :: map()
  def anthropic_tool!(tool, opts \\ []), do: tool |> anthropic_tool(opts) |> BeamWeaver.Policy.bang()

  @doc """
  Validates that a tool name can be sent to a provider.
  """
  @spec validate_provider_name(String.t(), atom()) :: :ok | {:error, Error.t()}
  def validate_provider_name(name, provider) when is_binary(name) do
    pattern = if provider == :deepseek, do: @deepseek_name, else: @provider_name

    if Regex.match?(pattern, name) do
      :ok
    else
      {:error,
       Error.new(:invalid_tool_name, "tool name is not valid for provider", %{
         name: name,
         provider: provider
       })}
    end
  end

  def validate_provider_name(name, provider) do
    {:error,
     Error.new(:invalid_tool_name, "tool name must be a string", %{
       name: inspect(name),
       provider: provider
     })}
  end

  defp maybe_strict_schema(schema, true), do: strict_schema(schema, :required)
  defp maybe_strict_schema(schema, _strict), do: schema

  @doc false
  @spec strict_json_schema(term(), keyword()) :: term()
  def strict_json_schema(schema, opts \\ [])

  def strict_json_schema(schema, opts) when is_map(schema) do
    optional = Keyword.get(opts, :optional, :required)

    schema
    |> BeamWeaver.MapShape.stringify_keys()
    |> strict_schema(optional)
  end

  def strict_json_schema(value, _opts), do: value

  defp strict_schema(schema, optional) when is_map(schema) do
    schema
    |> strip_strict_unsupported_keywords()
    |> strict_schema_children(optional)
    |> close_object_schema(optional)
  end

  defp strict_schema(value, _optional), do: value

  defp strict_schema_children(schema, optional) do
    for {key, value} <- schema, not (is_nil(value) and key in @schema_child_keys), into: %{} do
      cond do
        key in ["properties", "$defs", "definitions"] and is_map(value) ->
          {key, Map.new(value, fn {name, child} -> {name, strict_schema(child, optional)} end)}

        key in ["anyOf", "oneOf", "allOf", "items"] and is_list(value) ->
          {key, Enum.map(value, &strict_schema(&1, optional))}

        key == "items" ->
          {key, strict_schema(value, optional)}

        true ->
          {key, value}
      end
    end
  end

  defp close_object_schema(%{"properties" => properties} = schema, optional) when is_map(properties) do
    properties = maybe_nullable_optional_properties(properties, Map.get(schema, "required", []), optional)

    schema
    |> Map.put("properties", properties)
    |> Map.put("additionalProperties", false)
    |> put_strict_required(properties)
  end

  defp close_object_schema(%{"type" => type} = schema, _optional) do
    if Enum.any?(List.wrap(type), &(&1 in ["object", :object])) do
      schema
      |> Map.put_new("properties", %{})
      |> Map.put_new("required", [])
      |> Map.put("additionalProperties", false)
    else
      schema
    end
  end

  defp close_object_schema(schema, _optional), do: schema

  defp maybe_nullable_optional_properties(properties, _required, optional) when optional != :nullable,
    do: properties

  defp maybe_nullable_optional_properties(properties, required, :nullable) do
    required = required |> List.wrap() |> Enum.map(&to_string/1) |> MapSet.new()

    Map.new(properties, fn {name, property} ->
      name = to_string(name)
      property = if MapSet.member?(required, name), do: property, else: nullable_schema(property)
      {name, property}
    end)
  end

  defp nullable_schema(schema) when is_map(schema) do
    cond do
      nullable_schema?(schema) ->
        schema

      complex_nullable_schema?(schema) ->
        %{"anyOf" => [schema, %{"type" => "null"}]}

      Map.has_key?(schema, "type") ->
        schema
        |> Map.update!("type", fn type -> type |> List.wrap() |> Kernel.++(["null"]) |> Enum.uniq() end)
        |> maybe_add_null_enum()

      Map.has_key?(schema, "anyOf") ->
        Map.update!(schema, "anyOf", &append_null_variant/1)

      Map.has_key?(schema, "oneOf") ->
        schema
        |> Map.delete("oneOf")
        |> Map.put("anyOf", append_null_variant(Map.fetch!(schema, "oneOf")))

      true ->
        %{"anyOf" => [schema, %{"type" => "null"}]}
    end
  end

  defp nullable_schema(value), do: value

  defp complex_nullable_schema?(%{"type" => type} = schema) do
    types = List.wrap(type)
    complex_type? = Enum.any?(types, &(&1 in ["object", :object, "array", :array]))
    complex_type? and (Map.has_key?(schema, "properties") or Map.has_key?(schema, "items"))
  end

  defp complex_nullable_schema?(_schema), do: false

  defp nullable_schema?(%{"type" => types}) when is_list(types),
    do: Enum.any?(types, &(&1 in ["null", :null]))

  defp nullable_schema?(%{"type" => type}) when type in ["null", :null], do: true

  defp nullable_schema?(%{"anyOf" => schemas}) when is_list(schemas),
    do: Enum.any?(schemas, &nullable_schema?/1)

  defp nullable_schema?(_schema), do: false

  defp append_null_variant(schemas) when is_list(schemas) do
    if Enum.any?(schemas, &nullable_schema?/1) do
      schemas
    else
      schemas ++ [%{"type" => "null"}]
    end
  end

  defp append_null_variant(other), do: other

  defp maybe_add_null_enum(%{"enum" => enum} = schema) when is_list(enum) do
    if Enum.any?(enum, &is_nil/1), do: schema, else: Map.put(schema, "enum", enum ++ [nil])
  end

  defp maybe_add_null_enum(schema), do: schema

  defp strip_strict_unsupported_keywords(schema) when is_map(schema) do
    Map.drop(schema, [
      "default",
      "allOf",
      "not",
      "if",
      "then",
      "else",
      "dependentRequired",
      "dependentSchemas",
      "format",
      "minimum",
      "maximum",
      "exclusiveMinimum",
      "exclusiveMaximum",
      "multipleOf",
      "minLength",
      "maxLength",
      "pattern",
      "minItems",
      "maxItems",
      "uniqueItems",
      "minProperties",
      "maxProperties",
      "patternProperties",
      "propertyNames",
      "unevaluatedProperties"
    ])
  end

  defp put_strict_required(schema, properties) when map_size(properties) == 0, do: schema

  defp put_strict_required(schema, properties) do
    property_names = properties |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort()
    Map.put(schema, "required", property_names)
  end
end
