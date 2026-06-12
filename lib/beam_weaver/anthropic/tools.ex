defmodule BeamWeaver.Anthropic.Tools do
  @moduledoc """
  Builders for Anthropic custom and server-side tool declarations.
  """

  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Tool.Renderer

  @tool_type_to_beta %{
    "web_fetch_20250910" => "web-fetch-2025-09-10",
    "web_fetch_20260209" => "web-fetch-2026-02-09",
    "web_fetch_20260309" => "web-fetch-2026-03-09",
    "code_execution_20250522" => "code-execution-2025-05-22",
    "code_execution_20250825" => "code-execution-2025-08-25",
    "code_execution_20260120" => "code-execution-2026-01-20",
    "mcp_toolset" => "mcp-client-2025-11-20",
    "memory_20250818" => "context-management-2025-06-27",
    "computer_20241022" => "computer-use-2024-10-22",
    "computer_20250124" => "computer-use-2025-01-24",
    "computer_20251124" => "computer-use-2025-11-24",
    "advisor_20260301" => "advisor-2026-03-01",
    "tool_search_tool_regex_20251119" => "advanced-tool-use-2025-11-20",
    "tool_search_tool_bm25_20251119" => "advanced-tool-use-2025-11-20"
  }

  @builtin_prefixes [
    "text_editor_",
    "computer_",
    "bash_",
    "web_search_",
    "web_fetch_",
    "code_execution_",
    "advisor_",
    "mcp_toolset",
    "memory_",
    "tool_search_"
  ]

  @doc """
  Converts BeamWeaver tools, Anthropic tool maps, OpenAI-style function maps, and
  Anthropic built-ins to Anthropic request tool declarations.
  """
  @spec to_anthropic_tools([term()], keyword()) :: [map()]
  def to_anthropic_tools(tools, opts \\ []) when is_list(tools) do
    Enum.map(tools, &to_anthropic_tool(&1, opts))
  end

  @spec to_anthropic_tool(term(), keyword()) :: map()
  def to_anthropic_tool(tool, opts \\ [])
  def to_anthropic_tool(%Tool{} = tool, opts), do: Renderer.anthropic_tool!(tool, opts)

  def to_anthropic_tool(%{__struct__: module} = tool, opts) do
    if function_exported?(module, :name, 1) do
      Renderer.anthropic_tool!(tool, opts)
    else
      tool |> Map.from_struct() |> to_anthropic_tool(opts)
    end
  end

  def to_anthropic_tool(tool, opts) when is_map(tool) do
    tool
    |> BeamWeaver.MapShape.stringify_keys()
    |> normalize_tool_map(opts)
  end

  @doc """
  Builds a custom Anthropic tool declaration from a BeamWeaver tool.
  """
  @spec function(term(), keyword()) :: map()
  def function(tool, opts \\ []) do
    {render_opts, merge_opts} =
      Keyword.split(opts, [
        :strict,
        :cache_control,
        :defer_loading,
        :input_examples,
        :allowed_callers
      ])

    tool
    |> to_anthropic_tool(render_opts)
    |> merge_options(merge_opts)
  end

  @doc "Builds a text editor server tool."
  def text_editor(opts \\ []),
    do: build(Keyword.get(opts, :type, "text_editor_20250728"), Keyword.delete(opts, :type))

  @doc "Builds a computer-use server tool."
  def computer(opts \\ []),
    do: build(Keyword.get(opts, :type, "computer_20250124"), Keyword.delete(opts, :type))

  @doc "Builds a bash server tool."
  def bash(opts \\ []),
    do: build(Keyword.get(opts, :type, "bash_20250124"), Keyword.delete(opts, :type))

  @doc "Builds a web search server tool."
  def web_search(opts \\ []),
    do: build(Keyword.get(opts, :type, "web_search_20260209"), Keyword.delete(opts, :type))

  @doc "Builds a web fetch server tool."
  def web_fetch(opts \\ []),
    do: build(Keyword.get(opts, :type, "web_fetch_20260309"), Keyword.delete(opts, :type))

  @doc "Builds a code execution server tool."
  def code_execution(opts \\ []),
    do: build(Keyword.get(opts, :type, "code_execution_20260120"), Keyword.delete(opts, :type))

  @doc "Builds an advisor server tool."
  def advisor(opts \\ []),
    do: build(Keyword.get(opts, :type, "advisor_20260301"), Keyword.delete(opts, :type))

  @doc "Builds an MCP toolset declaration."
  def mcp_toolset(opts \\ []), do: build("mcp_toolset", opts)

  @doc "Builds a memory server tool."
  def memory(opts \\ []),
    do: build(Keyword.get(opts, :type, "memory_20250818"), Keyword.delete(opts, :type))

  @doc "Builds a tool-search server tool."
  def tool_search(opts \\ []),
    do:
      build(
        Keyword.get(opts, :type, "tool_search_tool_bm25_20251119"),
        Keyword.delete(opts, :type)
      )

  @doc false
  def required_betas(tools, existing \\ []) when is_list(tools) do
    inferred =
      tools
      |> Enum.flat_map(fn
        %{"type" => type, "input_examples" => examples}
        when is_binary(type) and is_list(examples) and examples != [] ->
          [Map.get(@tool_type_to_beta, type), "advanced-tool-use-2025-11-20"]

        %{"type" => type} when is_binary(type) ->
          [Map.get(@tool_type_to_beta, type)]

        %{"input_examples" => examples} when is_list(examples) and examples != [] ->
          ["advanced-tool-use-2025-11-20"]

        _tool ->
          []
      end)
      |> Enum.reject(&is_nil/1)

    (List.wrap(existing) ++ inferred)
    |> Enum.uniq()
  end

  @doc false
  def tool_choice(choice, opts \\ [])

  def tool_choice(nil, _opts), do: nil

  def tool_choice(choice, opts) do
    rendered =
      cond do
        is_map(choice) ->
          BeamWeaver.MapShape.stringify_keys(choice)

        choice in [:auto, "auto"] ->
          %{"type" => "auto"}

        choice in [:any, "any"] ->
          %{"type" => "any"}

        is_atom(choice) or is_binary(choice) ->
          %{"type" => "tool", "name" => to_string(choice)}

        true ->
          raise ArgumentError, "Anthropic tool_choice must be a map, atom, string, or nil"
      end

    case Keyword.fetch(opts, :parallel_tool_calls) do
      {:ok, false} -> Map.put(rendered, "disable_parallel_tool_use", true)
      {:ok, true} -> Map.put(rendered, "disable_parallel_tool_use", false)
      {:ok, nil} -> rendered
      :error -> rendered
    end
  end

  defp normalize_tool_map(%{"type" => type} = tool, _opts) when is_binary(type) do
    if builtin_tool?(tool), do: tool, else: maybe_openai_tool(tool)
  end

  defp normalize_tool_map(%{"name" => _name, "input_schema" => _schema} = tool, _opts), do: tool

  defp normalize_tool_map(%{"function" => function} = tool, opts) when is_map(function) do
    function
    |> Map.merge(Map.drop(tool, ["type", "function"]))
    |> normalize_tool_map(opts)
  end

  defp normalize_tool_map(tool, opts) do
    maybe_openai_tool(tool)
    |> Map.merge(render_opts(opts))
  end

  defp maybe_openai_tool(%{"parameters" => parameters, "name" => name} = tool) do
    %{
      "name" => name,
      "description" => tool["description"],
      "input_schema" => parameters,
      "strict" => tool["strict"]
    }
    |> reject_nil_values()
    |> merge_anthropic_extra(tool)
  end

  defp maybe_openai_tool(tool), do: tool

  defp builtin_tool?(%{"type" => type}) when is_binary(type) do
    Enum.any?(@builtin_prefixes, &String.starts_with?(type, &1))
  end

  defp builtin_tool?(_tool), do: false

  defp build(type, opts) do
    opts
    |> BeamWeaver.MapShape.stringify_entries()
    |> Map.put("type", type)
  end

  defp merge_options(tool, opts) do
    Map.merge(tool, BeamWeaver.MapShape.stringify_entries(opts))
  end

  defp render_opts(opts) do
    opts
    |> BeamWeaver.MapShape.stringify_entries()
    |> Map.take(["strict", "cache_control", "defer_loading", "input_examples", "allowed_callers"])
  end

  defp merge_anthropic_extra(tool, original) do
    Map.merge(
      tool,
      Map.take(original, [
        "cache_control",
        "defer_loading",
        "input_examples",
        "allowed_callers",
        "eager_input_streaming"
      ])
    )
  end

  defp reject_nil_values(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)
end
