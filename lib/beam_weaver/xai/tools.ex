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
  alias BeamWeaver.XAI.Error

  @builtin_types [
    "attachment_search",
    "code_execution",
    "web_search",
    "x_search",
    "code_interpreter",
    "collections_search",
    "file_search",
    "live_search",
    "mcp",
    "shell",
    "view_image",
    "view_x_video"
  ]

  @responses_tool_types [
    "attachment_search",
    "code_execution",
    "code_interpreter",
    "collections_search",
    "file_search",
    "function",
    "mcp",
    "shell",
    "view_image",
    "view_x_video",
    "web_search",
    "x_search"
  ]

  @chat_completions_tool_types ["function", "live_search"]

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
  @spec validate_responses_tools([map()]) :: :ok | {:error, Error.t()}
  def validate_responses_tools(tools),
    do: validate_tool_types(tools, @responses_tool_types, :responses)

  @doc false
  @spec validate_chat_completions_tools([map()]) :: :ok | {:error, Error.t()}
  def validate_chat_completions_tools(tools),
    do: validate_tool_types(tools, @chat_completions_tool_types, :chat_completions)

  @doc "Builds an xAI web search server tool declaration."
  @spec web_search(keyword()) :: map()
  def web_search(opts \\ []), do: build("web_search", opts)

  @doc "Builds an xAI X search server tool declaration."
  @spec x_search(keyword()) :: map()
  def x_search(opts \\ []), do: build("x_search", opts)

  @doc "Builds an xAI code interpreter server tool declaration."
  @spec code_interpreter(keyword()) :: map()
  def code_interpreter(opts \\ []), do: build("code_interpreter", opts)

  @doc "Builds an xAI code execution server tool declaration."
  @spec code_execution(keyword()) :: map()
  def code_execution(opts \\ []), do: build("code_execution", opts)

  @doc "Builds an xAI collections search server tool declaration."
  @spec collections_search(keyword()) :: map()
  def collections_search(opts \\ []), do: build("collections_search", opts)

  @doc "Builds an xAI file search server tool declaration."
  @spec file_search(keyword()) :: map()
  def file_search(opts \\ []), do: build("file_search", opts)

  @doc "Builds an xAI file attachment search server tool declaration."
  @spec attachment_search(keyword()) :: map()
  def attachment_search(opts \\ []), do: build("attachment_search", opts)

  @doc "Builds an xAI shell server tool declaration."
  @spec shell(keyword()) :: map()
  def shell(opts \\ []), do: build("shell", opts)

  @doc "Builds an xAI image understanding server tool declaration."
  @spec view_image(keyword()) :: map()
  def view_image(opts \\ []), do: build("view_image", opts)

  @doc "Builds an xAI X video understanding server tool declaration."
  @spec view_x_video(keyword()) :: map()
  def view_x_video(opts \\ []), do: build("view_x_video", opts)

  @doc "Builds an xAI Chat Completions live search server tool declaration."
  @spec live_search(keyword()) :: map()
  def live_search(opts \\ []), do: build("live_search", opts)

  @doc "Builds an xAI MCP server tool declaration."
  @spec mcp(String.t(), String.t(), keyword()) :: map()
  def mcp(server_label, server_url, opts \\ [])
      when is_binary(server_label) and is_binary(server_url) do
    "mcp"
    |> build(opts)
    |> Map.put("server_label", server_label)
    |> Map.put("server_url", server_url)
  end

  @doc "Builds an OpenAI-compatible function tool declaration."
  @spec function(term(), keyword()) :: map()
  def function(tool, opts \\ []), do: ToolCalling.function(tool, opts)

  defp builtin_tool?(%{"type" => type}) when is_binary(type),
    do: type in @builtin_types

  defp builtin_tool?(_tool), do: false

  defp validate_tool_types(tools, allowed, api) when is_list(tools) do
    unsupported =
      tools
      |> Enum.map(&Map.get(&1, "type"))
      |> Enum.reject(&(is_nil(&1) or &1 in allowed))
      |> Enum.uniq()

    case unsupported do
      [] ->
        :ok

      types ->
        {:error,
         Error.new(:unsupported_feature, "xAI tool type is not supported by this API", %{
           provider: :xai,
           api: api,
           feature: :tools,
           unsupported: types,
           supported: Enum.sort(allowed)
         })}
    end
  end

  defp build(type, opts) do
    opts
    |> BeamWeaver.MapShape.stringify_entries()
    |> Map.put("type", type)
  end
end
