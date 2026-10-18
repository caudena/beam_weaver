defmodule BeamWeaver.Google.Tools do
  @moduledoc ~S"""
  Construct Gemini-native tool declarations without executing tools.

  Search, code execution and other hosted services execute at Google when the
  model selects them. File-search and MCP declarations require actual resources.
  Computer-use declarations require an application-side browser/desktop executor.
  See [Google Gemini](providers/google.md#built-in-tools) for a real search call.
  """

  import BeamWeaver.MapShape, only: [put_present: 3]

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Provider.Options
  alias BeamWeaver.Tool.Schema

  @unsupported_function_parameter_schema_keys MapSet.new([
                                                "$defs",
                                                "$id",
                                                "$schema",
                                                "additionalProperties",
                                                "default",
                                                "definitions",
                                                "dependentSchemas",
                                                "examples",
                                                "patternProperties",
                                                "propertyNames",
                                                "title",
                                                "unevaluatedProperties"
                                              ])

  @doc """
  Declares hosted Google Search; inspect response grounding to verify actual use.
  """
  def google_search(opts \\ %{}), do: %{"googleSearch" => Options.stringify_keys(Map.new(opts))}

  @doc """
  Declares Google Maps grounding where supported by the selected model/account.
  """
  def google_maps(opts \\ %{}), do: %{"googleMaps" => Options.stringify_keys(Map.new(opts))}

  @doc """
  Declares hosted code execution where supported.
  """
  def code_execution(opts \\ %{}), do: %{"codeExecution" => Options.stringify_keys(Map.new(opts))}

  @doc """
  Declares search over actual File Search store names supplied by the application.
  """
  def file_search(store_names, opts \\ []) do
    config =
      opts
      |> Map.new()
      |> Map.put(:fileSearchStoreNames, List.wrap(store_names))
      |> Options.stringify_keys()

    %{"fileSearch" => config}
  end

  @doc """
  Declares URL-context retrieval for provider-supported public content.
  """
  def url_context(opts \\ %{}), do: %{"urlContext" => Options.stringify_keys(Map.new(opts))}

  @doc """
  Declares client computer actions; the application must execute them and return results.
  """
  def computer_use(opts \\ %{}), do: %{"computerUse" => Options.stringify_keys(Map.new(opts))}

  @doc """
  Declares configured MCP servers; their access and execution prerequisites remain external.
  """
  def mcp_servers(servers),
    do: %{"mcpServers" => Options.normalize_option_list(List.wrap(servers))}

  @doc false
  def render_tools(nil), do: {:ok, []}
  def render_tools([]), do: {:ok, []}

  def render_tools(tools) when is_list(tools) do
    {builtins, custom} = Enum.split_with(tools, &builtin_tool?/1)

    declarations = Enum.map(custom, &function_declaration/1)
    {:ok, Enum.map(builtins, &builtin_tool/1) ++ function_declarations(declarations)}
  rescue
    error in ArgumentError -> {:error, Error.new(:invalid_tool, Exception.message(error))}
  end

  # Gemini takes the function declarations together, in one tool.
  defp function_declarations([]), do: []
  defp function_declarations(declarations), do: [%{"functionDeclarations" => declarations}]

  @doc false
  def render_tool_choice(choice) when choice in [nil, false], do: {:ok, nil}

  def render_tool_choice(choice) when choice in [:validated, "validated"],
    do: {:ok, function_calling_config("VALIDATED")}

  def render_tool_choice(choice) when choice in [:auto, "auto"], do: {:ok, function_calling_config("AUTO")}
  def render_tool_choice(choice) when choice in [:none, "none"], do: {:ok, function_calling_config("NONE")}

  def render_tool_choice(choice) when choice in [:any, "any", :required, "required"],
    do: {:ok, function_calling_config("ANY")}

  def render_tool_choice(%{name: name}), do: render_tool_choice(name)
  def render_tool_choice(%{"name" => name}), do: render_tool_choice(name)
  def render_tool_choice(name) when is_binary(name), do: {:ok, function_calling_config("ANY", [name])}

  def render_tool_choice(choice),
    do: {:error, Error.new(:invalid_tool_choice, "Google tool_choice is invalid", %{choice: choice})}

  defp function_declaration(tool) when is_map(tool) and not is_struct(tool) do
    cond do
      Map.has_key?(tool, "functionDeclarations") or Map.has_key?(tool, :functionDeclarations) ->
        raise ArgumentError,
              "functionDeclarations must be passed as provider tools, not custom tools"

      Map.has_key?(tool, "name") or Map.has_key?(tool, :name) ->
        parameters =
          BeamWeaver.MapAccess.get(tool, :parameters) ||
            BeamWeaver.MapAccess.get(tool, :input_schema) || %{}

        %{
          "name" => BeamWeaver.MapAccess.get(tool, :name),
          "description" => BeamWeaver.MapAccess.get(tool, :description),
          "parameters" => function_parameters(parameters)
        }
        |> Options.reject_nil_values()

      true ->
        raise ArgumentError, "Google custom tool map must include a name"
    end
  end

  defp function_declaration(tool) do
    %{
      "name" => Tool.name(tool),
      "description" => Tool.description(tool),
      "parameters" => function_parameters(Tool.input_schema(tool))
    }
    |> Options.reject_nil_values()
  end

  defp function_parameters(schema) when is_map(schema) do
    schema = Options.stringify_keys(schema)

    case Schema.dereference_refs(schema) do
      {:ok, dereferenced} -> sanitize_function_parameter_schema(dereferenced)
      {:error, %Error{} = error} -> raise ArgumentError, error.message
    end
  end

  defp function_parameters(schema), do: schema

  defp sanitize_function_parameter_schema(schema) when is_map(schema) do
    schema
    |> normalize_nullable_type()
    |> Enum.reject(fn {key, _value} ->
      MapSet.member?(@unsupported_function_parameter_schema_keys, key)
    end)
    |> Map.new(fn
      {"properties", properties} when is_map(properties) ->
        {"properties",
         Map.new(properties, fn {name, property_schema} ->
           {to_string(name), sanitize_schema_value(property_schema)}
         end)}

      {key, value} ->
        {key, sanitize_schema_value(value)}
    end)
  end

  defp sanitize_function_parameter_schema(value), do: value

  defp normalize_nullable_type(%{"type" => types} = schema) when is_list(types) do
    {null_types, concrete_types} = Enum.split_with(types, &(&1 == "null"))

    cond do
      concrete_types == [] ->
        Map.put(schema, "type", "string")

      length(concrete_types) == 1 ->
        schema
        |> Map.put("type", hd(concrete_types))
        |> maybe_mark_nullable(null_types)

      null_types != [] ->
        schema
        |> Map.delete("type")
        |> Map.put("anyOf", Enum.map(concrete_types, &%{"type" => &1}))
        |> Map.put("nullable", true)

      true ->
        schema
        |> Map.delete("type")
        |> Map.put("anyOf", Enum.map(concrete_types, &%{"type" => &1}))
    end
  end

  defp normalize_nullable_type(schema), do: schema

  defp maybe_mark_nullable(schema, []), do: schema
  defp maybe_mark_nullable(schema, _null_types), do: Map.put(schema, "nullable", true)

  defp sanitize_schema_value(value) when is_map(value), do: sanitize_function_parameter_schema(value)
  defp sanitize_schema_value(value) when is_list(value), do: Enum.map(value, &sanitize_schema_value/1)
  defp sanitize_schema_value(value), do: value

  @builtin_tool_keys %{
    "google_search" => "googleSearch",
    "google_maps" => "googleMaps",
    "code_execution" => "codeExecution",
    "file_search" => "fileSearch",
    "url_context" => "urlContext",
    "computer_use" => "computerUse",
    "mcp_servers" => "mcpServers"
  }
  @builtin_tool_kinds Map.new(@builtin_tool_keys, fn {key, wire_key} -> {wire_key, String.to_atom(key)} end)

  @doc false
  # The kinds of the built-in tools in a tool list, such as `:computer_use`.
  def builtin_tool_kinds(tools) do
    tools
    |> Enum.filter(&builtin_tool?/1)
    |> Enum.flat_map(fn tool -> tool |> Map.keys() |> Enum.map(&builtin_tool_key(to_string(&1))) end)
    |> Enum.map(&Map.get(@builtin_tool_kinds, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  @doc false
  def mixed_execution?(tools) do
    Enum.any?(tools, &builtin_tool?/1) and Enum.any?(tools, &(not builtin_tool?(&1)))
  end

  defp builtin_tool?(tool) when is_map(tool) do
    not is_struct(tool) and not Map.has_key?(tool, "name") and not Map.has_key?(tool, :name)
  end

  defp builtin_tool?(_tool), do: false

  defp builtin_tool(tool) when is_map(tool) do
    tool
    |> Options.stringify_keys()
    |> Map.new(fn {key, value} -> {builtin_tool_key(key), value} end)
  end

  defp function_calling_config(mode, names \\ nil) do
    config =
      %{"mode" => mode}
      |> put_present("allowedFunctionNames", names)

    %{"functionCallingConfig" => config}
  end

  defp builtin_tool_key(key), do: Map.get(@builtin_tool_keys, key, key)
end
