defmodule BeamWeaver.Anthropic.Tools do
  @moduledoc """
  Builders for Anthropic custom and server-side tool declarations.
  """

  import BeamWeaver.MapShape, only: [reject_nil_values: 1]

  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Tool.Renderer

  @tool_type_to_beta %{
    "mcp_toolset" => "mcp-client-2025-11-20",
    "computer_20241022" => "computer-use-2024-10-22",
    "computer_20250124" => "computer-use-2025-01-24",
    "computer_20251124" => "computer-use-2025-11-24",
    "advisor_20260301" => "advisor-tool-2026-03-01"
  }

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

  def to_anthropic_tool(tool, opts) when is_atom(tool), do: Renderer.anthropic_tool!(tool, opts)

  def to_anthropic_tool(%{__struct__: module} = tool, opts) do
    if Tool.implemented_by?(module) do
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
    |> Map.merge(BeamWeaver.MapShape.stringify_entries(merge_opts))
  end

  @doc "Builds a text editor server tool."
  def text_editor(opts \\ []), do: server_tool(opts, "text_editor_20250728")

  @doc "Builds a computer-use server tool."
  def computer(opts \\ []), do: server_tool(opts, "computer_20250124")

  @doc "Builds a bash server tool."
  def bash(opts \\ []), do: server_tool(opts, "bash_20250124")

  @doc "Builds a web search server tool."
  def web_search(opts \\ []), do: server_tool(opts, "web_search_20260318", name: "web_search")

  @doc "Builds a web fetch server tool."
  def web_fetch(opts \\ []), do: server_tool(opts, "web_fetch_20260318", name: "web_fetch")

  @doc "Builds a code execution server tool."
  def code_execution(opts \\ []), do: server_tool(opts, "code_execution_20260521", name: "code_execution")

  @doc "Builds an advisor server tool."
  def advisor(opts \\ []), do: server_tool(opts, "advisor_20260301")

  @doc "Builds an Anthropic browser toolset."
  def browser_toolset(opts \\ []), do: server_tool(opts, "browser_toolset_20260801")

  @doc "Builds an Anthropic computer toolset."
  def computer_toolset(opts \\ []), do: server_tool(opts, "computer_toolset_20260801")

  @doc "Builds an MCP toolset declaration."
  def mcp_toolset(opts \\ []), do: build("mcp_toolset", opts)

  @doc "Builds a memory server tool."
  def memory(opts \\ []), do: server_tool(opts, "memory_20250818")

  @doc "Builds a tool-search server tool."
  def tool_search(opts \\ []), do: server_tool(opts, "tool_search_tool_bm25_20251119")

  @doc false
  def required_betas(tools, existing) when is_list(tools) do
    inferred = for %{"type" => type} when is_map_key(@tool_type_to_beta, type) <- tools, do: @tool_type_to_beta[type]
    Enum.uniq(List.wrap(existing) ++ inferred)
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

        choice in [:none, "none"] ->
          %{"type" => "none"}

        choice in [:any, "any", :required, "required"] ->
          %{"type" => "any"}

        is_atom(choice) or is_binary(choice) ->
          %{"type" => "tool", "name" => to_string(choice)}

        true ->
          raise ArgumentError, "Anthropic tool_choice must be a map, atom, string, or nil"
      end

    case Keyword.get(opts, :parallel_tool_calls) do
      nil -> rendered
      parallel when is_boolean(parallel) -> Map.put(rendered, "disable_parallel_tool_use", not parallel)
    end
  end

  defp normalize_tool_map(%{"type" => type} = tool, _opts) when is_binary(type) do
    if type in ["function", "custom"], do: maybe_openai_tool(tool), else: tool
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

  defp server_tool(opts, type, defaults \\ []) do
    {type, opts} = Keyword.pop(opts, :type, type)
    build(type, Keyword.merge(defaults, opts))
  end

  defp build(type, opts) do
    opts
    |> BeamWeaver.MapShape.stringify_entries()
    |> Map.put("type", type)
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
end
