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
    cond do
      Enum.any?(tools, &(&1["type"] == "live_search")) ->
        {:error,
         Error.new(:unsupported_feature, "live_search requires Chat Completions", %{
           provider: :xai,
           api: :responses,
           unsupported: ["live_search"]
         })}

      Enum.all?(tools, &(is_binary(&1["type"]) and &1["type"] != "")) ->
        :ok

      true ->
        {:error, Error.new(:invalid_tool, "xAI tools require a type")}
    end
  end

  @doc false
  @spec validate_chat_completions_tools([map()]) :: :ok | {:error, Error.t()}
  def validate_chat_completions_tools(tools),
    do: validate_tool_types(tools, @chat_completions_tool_types, :chat_completions)

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

  @doc "Builds an xAI collections search server tool declaration."
  @spec collections_search(keyword()) :: map()
  def collections_search(opts \\ []), do: ToolCalling.build("collections_search", opts)

  @doc "Builds an xAI file search server tool declaration."
  @spec file_search(keyword()) :: map()
  def file_search(opts \\ []), do: ToolCalling.build("file_search", opts)

  @doc "Builds an xAI file attachment search server tool declaration."
  @spec attachment_search(keyword()) :: map()
  def attachment_search(opts \\ []), do: ToolCalling.build("attachment_search", opts)

  @doc "Builds an xAI shell server tool declaration."
  @spec shell(keyword()) :: map()
  def shell(opts \\ []), do: ToolCalling.build("shell", opts)

  @doc "Builds an xAI image understanding server tool declaration."
  @spec view_image(keyword()) :: map()
  def view_image(opts \\ []), do: ToolCalling.build("view_image", opts)

  @doc "Builds an xAI X video understanding server tool declaration."
  @spec view_x_video(keyword()) :: map()
  def view_x_video(opts \\ []), do: ToolCalling.build("view_x_video", opts)

  @doc "Builds an xAI Chat Completions live search server tool declaration."
  @spec live_search(keyword()) :: map()
  def live_search(opts \\ []), do: ToolCalling.build("live_search", opts)

  @doc "Builds an xAI MCP server tool declaration."
  @spec mcp(String.t(), String.t(), keyword()) :: map()
  def mcp(server_label, server_url, opts \\ []), do: ToolCalling.mcp(server_label, server_url, opts)

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
end
