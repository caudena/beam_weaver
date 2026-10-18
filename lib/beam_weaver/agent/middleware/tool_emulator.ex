defmodule BeamWeaver.Agent.Middleware.ToolEmulator do
  @moduledoc """
  Emulates selected tool calls with a chat model.

  This is a testing and simulation middleware. It keeps the tool execution
  boundary native: selected calls are converted to a model prompt and returned
  as normal tool messages, while non-selected calls continue through the
  original tool handler.
  """

  use BeamWeaver.Agent.Middleware

  alias BeamWeaver.Agent.Middleware.Helpers
  alias BeamWeaver.Agent.ToolCallRequest
  alias BeamWeaver.Core.ChatModel
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Models.FakeChatModel

  @default_model %FakeChatModel{response: Message.assistant("Emulated response")}

  @default_prompt_template "You are emulating a tool call for testing purposes.\n\n" <>
                             "Tool: {tool}\nDescription: {description}\nArguments: {args}\n\n" <>
                             "Generate a realistic response that this tool would return. " <>
                             "Return only the tool output."

  defstruct tools: nil, emulate_all?: true, model: @default_model, prompt_template: @default_prompt_template

  def new(opts \\ []) do
    tools = Keyword.get(opts, :tools)

    %__MODULE__{
      tools: Helpers.tool_names(tools),
      emulate_all?: is_nil(tools),
      model: opts |> Keyword.get(:model, @default_model) |> Helpers.chat_model!(),
      prompt_template: Keyword.get(opts, :prompt_template, @default_prompt_template)
    }
  end

  @impl true
  def name(_middleware), do: :tool_emulator

  @impl true
  def wrap_tool_call(%__MODULE__{} = middleware, %ToolCallRequest{} = request, handler) do
    if emulate?(middleware, request) do
      emulate_tool(middleware, request)
    else
      handler.(request)
    end
  end

  defp emulate?(%__MODULE__{emulate_all?: true}, _request), do: true

  defp emulate?(%__MODULE__{tools: tools}, %ToolCallRequest{} = request) do
    MapSet.member?(tools, tool_name(request))
  end

  defp emulate_tool(%__MODULE__{} = middleware, %ToolCallRequest{} = request) do
    prompt = prompt(middleware, request)

    with {:ok, %Message{} = response} <-
           ChatModel.invoke(middleware.model, [Message.user(prompt)], []) do
      Message.tool(Message.text(response),
        tool_call_id: Helpers.tool_call_id(request.tool_call),
        name: tool_name(request),
        metadata: %{emulated?: true}
      )
    end
  end

  defp prompt(%__MODULE__{} = middleware, %ToolCallRequest{} = request) do
    middleware.prompt_template
    |> String.replace("{tool}", tool_name(request))
    |> String.replace("{description}", tool_description(request))
    |> String.replace("{args}", inspect(tool_args(request)))
  end

  defp tool_description(%ToolCallRequest{tool: nil}), do: "No description available"
  defp tool_description(%ToolCallRequest{tool: tool}), do: Tool.description(tool)

  defp tool_name(%ToolCallRequest{tool_call: %{name: name}}), do: to_string(name)
  defp tool_name(%ToolCallRequest{tool_call: %{"name" => name}}), do: to_string(name)
  defp tool_name(_request), do: "unknown_tool"

  defp tool_args(%ToolCallRequest{tool_call: %{args: args}}), do: args || %{}
  defp tool_args(%ToolCallRequest{tool_call: %{"args" => args}}), do: args || %{}
  defp tool_args(_request), do: %{}
end
