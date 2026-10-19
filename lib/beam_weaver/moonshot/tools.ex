defmodule BeamWeaver.Moonshot.Tools do
  @moduledoc """
  Tool declaration helpers for Moonshot/Kimi Chat Completions.
  """

  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Error
  alias BeamWeaver.OpenAI.ChatCompletions
  alias BeamWeaver.OpenAI.ToolCalling

  @allowed_types ["builtin_function", "function"]
  @function_name ~r/^[a-zA-Z0-9_-]{1,64}$/
  @max_tools 128

  @doc "Builds Kimi's built-in web-search tool declaration."
  @spec web_search(keyword() | map()) :: map()
  def web_search(opts \\ []) do
    %{
      "type" => "builtin_function",
      "function" => opts |> BeamWeaver.MapShape.stringify_entries() |> Map.put("name", "$web_search")
    }
  end

  @doc "Builds an OpenAI-compatible function tool declaration."
  @spec function(term(), keyword()) :: map()
  def function(tool, opts \\ []), do: ToolCalling.function(tool, opts)

  @doc "Builds a Kimi K3 contentless system message that loads tools dynamically."
  @spec dynamic_message([term()]) :: Message.t()
  def dynamic_message(tools) when is_list(tools) do
    Message.system("", metadata: %{moonshot_dynamic_tools: to_chat_tools(tools)})
  end

  @doc "Converts tools to Moonshot Chat Completions declarations."
  @spec to_chat_tools([term()]) :: [map()]
  def to_chat_tools(tools) when is_list(tools), do: Enum.map(tools, &to_chat_tool/1)

  @doc """
  Converts one tool to a Moonshot Chat Completions declaration.

  Raises `ArgumentError` for a tool Kimi can't take, such as a Responses API
  built-in tool.
  """
  @spec to_chat_tool(term()) :: map()
  def to_chat_tool(tool) do
    case render_chat_tool(tool) do
      {:ok, rendered} -> rendered
      {:error, error} -> raise ArgumentError, error.message
    end
  end

  # Like `to_chat_tools/1`, with an `:unsupported_feature` error instead of a
  # raise for a tool that isn't a function or Kimi built-in.
  @doc false
  @spec render_chat_tools([term()]) :: {:ok, [map()]} | {:error, Error.t()}
  def render_chat_tools(tools) when is_list(tools), do: BeamWeaver.Result.traverse(tools, &render_chat_tool/1)

  defp render_chat_tool(tool) when is_map(tool) and not is_struct(tool) do
    tool = BeamWeaver.MapShape.stringify_keys(tool)
    if tool["type"] == "builtin_function", do: {:ok, tool}, else: render_function_tool(tool)
  end

  defp render_chat_tool(tool), do: render_function_tool(tool)

  defp render_function_tool(tool) do
    with {:error, error} <- ChatCompletions.Messages.Request.render_tool(tool),
         do: {:error, %{error | details: Map.put(error.details, :provider, :moonshot)}}
  end

  @doc false
  @spec validate_chat_tools([map()]) :: :ok | {:error, Error.t()}
  def validate_chat_tools(tools) when is_list(tools) do
    if length(tools) > @max_tools,
      do:
        error(:invalid_request, "Moonshot supports at most 128 tools",
          feature: :tools,
          count: length(tools),
          max: @max_tools
        ),
      else: Enum.find_value(tools, :ok, fn tool -> with :ok <- validate_tool(tool), do: nil end)
  end

  defp error(type, message, details),
    do: {:error, Error.new(type, message, Enum.into(details, %{provider: :moonshot}))}

  @doc false
  @spec web_search_tool?(map()) :: boolean()
  def web_search_tool?(tool) when is_map(tool) do
    tool = BeamWeaver.MapShape.stringify_keys(tool)
    get_in(tool, ["function", "name"]) == "$web_search"
  end

  def web_search_tool?(_tool), do: false

  defp validate_tool(%{"type" => type} = tool) when is_binary(type) do
    cond do
      type not in @allowed_types ->
        error(:unsupported_feature, "Moonshot tool type is not supported",
          api: :chat_completions,
          feature: :tools,
          unsupported: [type],
          supported: @allowed_types
        )

      type == "builtin_function" ->
        validate_builtin_tool(tool)

      true ->
        validate_function_tool(tool)
    end
  end

  defp validate_tool(tool), do: error(:invalid_request, "Moonshot tool declaration is invalid", tool: inspect(tool))

  defp validate_builtin_tool(tool) do
    case get_in(tool, ["function", "name"]) do
      "$web_search" ->
        :ok

      name ->
        error(:unsupported_feature, "Moonshot built-in tool is not supported",
          api: :chat_completions,
          feature: :tools,
          unsupported: [name],
          supported: ["$web_search"]
        )
    end
  end

  defp validate_function_tool(tool) do
    function = tool["function"] || %{}
    name = function["name"]

    cond do
      not is_binary(name) or not Regex.match?(@function_name, name) ->
        error(:invalid_request, "Moonshot function tool name is invalid",
          name: name,
          pattern: Regex.source(@function_name)
        )

      is_map(function["parameters"]) ->
        :ok

      true ->
        error(:invalid_request, "Moonshot function tools require an input schema", name: name)
    end
  end
end
