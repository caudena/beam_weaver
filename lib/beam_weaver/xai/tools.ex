defmodule BeamWeaver.XAI.Tools do
  @moduledoc """
  Builders and renderers for xAI tool declarations.

  xAI accepts the OpenAI-compatible function/tool shape and also exposes
  server-side tools such as web search and x search. Custom BeamWeaver tools are
  rendered through the existing OpenAI-compatible renderers while xAI built-ins
  are passed through unchanged.
  """

  alias BeamWeaver.OpenAI.ChatCompletions
  alias BeamWeaver.OpenAI.ToolCalling
  alias BeamWeaver.Core.Error

  @builtin_types [
    "code_execution",
    "web_search",
    "x_search",
    "code_interpreter",
    "collections_search",
    "file_search",
    "mcp",
    "shell"
  ]

  @chat_completions_tool_types ["function"]

  @doc """
  Converts tools to xAI Responses API declarations.
  """
  @spec to_responses_tools([term()]) :: [map()]
  def to_responses_tools(tools) when is_list(tools) do
    Enum.map(tools, &to_responses_tool/1)
  end

  @doc """
  Converts one tool to the xAI Responses API shape.
  """
  @spec to_responses_tool(term()) :: map()
  def to_responses_tool(tool), do: ToolCalling.to_openai_tool(tool)

  @doc """
  Converts tools to xAI Chat Completions declarations.
  """
  @spec to_chat_completions_tools([term()]) :: [map()]
  def to_chat_completions_tools(tools) when is_list(tools) do
    Enum.map(tools, &to_chat_completions_tool/1)
  end

  @doc """
  Converts one tool to the xAI Chat Completions shape.
  """
  @spec to_chat_completions_tool(term()) :: map()
  def to_chat_completions_tool(tool) when is_map(tool) do
    tool = BeamWeaver.MapShape.stringify_keys(tool)

    if builtin_tool?(tool) do
      tool
    else
      ChatCompletions.Messages.tool_to_openai(tool)
    end
  end

  def to_chat_completions_tool(tool), do: ChatCompletions.Messages.tool_to_openai(tool)

  @doc false
  @spec render_chat_completions_tools([term()]) :: {:ok, [map()]} | {:error, Error.t()}
  def render_chat_completions_tools(tools) when is_list(tools) do
    BeamWeaver.Result.traverse(tools, fn tool ->
      tool = if is_map(tool) and not is_struct(tool), do: BeamWeaver.MapShape.stringify_keys(tool), else: tool

      if builtin_tool?(tool),
        do: {:ok, tool},
        else: ChatCompletions.Messages.Request.render_tool(tool)
    end)
  end

  @doc false
  @spec validate_responses_tools([map()]) :: :ok | {:error, Error.t()}
  def validate_responses_tools(tools) do
    if Enum.all?(tools, &(is_binary(&1["type"]) and &1["type"] != "")),
      do: :ok,
      else: {:error, Error.new(:invalid_tool, "xAI tools require a type")}
  end

  @doc false
  @spec validate_chat_completions_tools([map()]) :: :ok | {:error, Error.t()}
  def validate_chat_completions_tools(tools) when is_list(tools) do
    unsupported =
      tools
      |> Enum.map(&Map.get(&1, "type"))
      |> Enum.reject(&(is_nil(&1) or &1 in @chat_completions_tool_types))
      |> Enum.uniq()

    case unsupported do
      [] ->
        :ok

      types ->
        {:error,
         Error.new(:unsupported_feature, "xAI tool type is not supported by this API", %{
           provider: :xai,
           api: :chat_completions,
           feature: :tools,
           unsupported: types,
           supported: Enum.sort(@chat_completions_tool_types)
         })}
    end
  end

  @doc "Builds an xAI web search server tool declaration."
  @spec web_search(keyword()) :: map()
  def web_search(opts \\ []), do: ToolCalling.build("web_search", opts)

  @doc "Builds an xAI X search server tool declaration."
  @spec x_search(keyword()) :: map()
  def x_search(opts \\ []), do: ToolCalling.build("x_search", opts)

  @doc "Builds an xAI code interpreter server tool declaration."
  @spec code_interpreter(keyword()) :: map()
  def code_interpreter(opts \\ []), do: ToolCalling.build("code_interpreter", opts)

  @doc "Builds an xAI code execution server tool declaration."
  @spec code_execution(keyword()) :: map()
  def code_execution(opts \\ []), do: ToolCalling.build("code_execution", opts)

  @doc "Builds an xAI collections search declaration; pass vector_store_ids: with the collection IDs."
  @spec collections_search(keyword()) :: map()
  def collections_search(opts \\ []), do: ToolCalling.build("collections_search", opts)

  @doc "Builds an xAI file search declaration; pass vector_store_ids: with the collection IDs."
  @spec file_search(keyword()) :: map()
  def file_search(opts \\ []), do: ToolCalling.build("file_search", opts)

  @doc "Builds an xAI shell declaration with the environment supplied in its options."
  @spec shell(keyword()) :: map()
  def shell(opts \\ []), do: ToolCalling.build("shell", opts)

  @doc "Builds an xAI MCP server tool declaration."
  @spec mcp(String.t(), String.t(), keyword()) :: map()
  def mcp(server_label, server_url, opts \\ []), do: ToolCalling.mcp(server_label, server_url, opts)

  @doc "Builds an OpenAI-compatible function tool declaration."
  @spec function(term(), keyword()) :: map()
  def function(tool, opts \\ []), do: ToolCalling.function(tool, opts)

  defp builtin_tool?(%{"type" => type}) when is_binary(type),
    do: type in @builtin_types

  defp builtin_tool?(_tool), do: false
end
