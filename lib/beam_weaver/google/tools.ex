defmodule BeamWeaver.Google.Tools do
  @moduledoc """
  Google Gemini tool declaration helpers.
  """

  @behaviour BeamWeaver.Provider.ToolRenderer

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Provider.Options
  alias BeamWeaver.Tool.Schema

  @builtin_tool_keys [
    "google_search",
    "googleSearch",
    "google_search_retrieval",
    "googleSearchRetrieval",
    "google_maps",
    "googleMaps",
    "code_execution",
    "codeExecution",
    "file_search",
    "fileSearch",
    "url_context",
    "urlContext",
    "computer_use",
    "computerUse",
    "mcp_servers",
    "mcpServers"
  ]

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

  def google_search(opts \\ %{}), do: %{"googleSearch" => Options.stringify_keys(Map.new(opts))}

  def google_search_retrieval(opts \\ %{}),
    do: %{"googleSearchRetrieval" => Options.stringify_keys(Map.new(opts))}

  def google_maps(opts \\ %{}), do: %{"googleMaps" => Options.stringify_keys(Map.new(opts))}

  def code_execution(opts \\ %{}), do: %{"codeExecution" => Options.stringify_keys(Map.new(opts))}

  def file_search(store_names, opts \\ []) do
    config =
      opts
      |> Map.new()
      |> Map.put(:fileSearchStoreNames, List.wrap(store_names))
      |> Options.stringify_keys()

    %{"fileSearch" => config}
  end

  def url_context(opts \\ %{}), do: %{"urlContext" => Options.stringify_keys(Map.new(opts))}

  def computer_use(opts \\ %{}), do: %{"computerUse" => Options.stringify_keys(Map.new(opts))}

  def mcp_servers(servers),
    do: %{"mcpServers" => Options.normalize_option_list(List.wrap(servers))}

  @impl true
  def render_tools(nil, _opts), do: {:ok, []}
  def render_tools([], _opts), do: {:ok, []}

  def render_tools(tools, _opts) when is_list(tools) do
    {builtins, custom} = Enum.split_with(tools, &builtin_tool?/1)

    declarations =
      custom
      |> Enum.map(&function_declaration/1)

    rendered =
      Enum.map(builtins, &builtin_tool/1) ++
        if declarations == [], do: [], else: [%{"functionDeclarations" => declarations}]

    {:ok, rendered}
  rescue
    exception -> {:error, Error.new(:invalid_tool, Exception.message(exception))}
  end

  @impl true
  def render_tool_choice(nil, _tools, _opts), do: {:ok, nil}
  def render_tool_choice(false, _tools, _opts), do: {:ok, nil}
  def render_tool_choice(:auto, _tools, _opts), do: {:ok, function_calling_config("AUTO")}
  def render_tool_choice("auto", _tools, _opts), do: {:ok, function_calling_config("AUTO")}
  def render_tool_choice(:any, tools, opts), do: render_tool_choice(:required, tools, opts)
  def render_tool_choice("any", tools, opts), do: render_tool_choice(:required, tools, opts)
  def render_tool_choice(:required, _tools, _opts), do: {:ok, function_calling_config("ANY")}
  def render_tool_choice("required", _tools, _opts), do: {:ok, function_calling_config("ANY")}
  def render_tool_choice(%{name: name}, tools, opts), do: render_tool_choice(name, tools, opts)

  def render_tool_choice(%{"name" => name}, tools, opts),
    do: render_tool_choice(name, tools, opts)

  def render_tool_choice(name, _tools, _opts) when is_binary(name),
    do: {:ok, function_calling_config("ANY", [name])}

  def render_tool_choice(choice, _tools, _opts),
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

  defp sanitize_schema_value(value) when is_map(value), do: sanitize_function_parameter_schema(value)
  defp sanitize_schema_value(value) when is_list(value), do: Enum.map(value, &sanitize_schema_value/1)
  defp sanitize_schema_value(value), do: value

  defp builtin_tool?(tool) when is_map(tool) do
    keys = Enum.map(Map.keys(tool), &to_string/1)
    Enum.any?(@builtin_tool_keys, &(&1 in keys))
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
      |> maybe_put("allowedFunctionNames", names)

    %{"functionCallingConfig" => config}
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp builtin_tool_key("google_search"), do: "googleSearch"
  defp builtin_tool_key("google_search_retrieval"), do: "googleSearchRetrieval"
  defp builtin_tool_key("google_maps"), do: "googleMaps"
  defp builtin_tool_key("code_execution"), do: "codeExecution"
  defp builtin_tool_key("file_search"), do: "fileSearch"
  defp builtin_tool_key("url_context"), do: "urlContext"
  defp builtin_tool_key("computer_use"), do: "computerUse"
  defp builtin_tool_key("mcp_servers"), do: "mcpServers"
  defp builtin_tool_key(key), do: key
end
