defmodule BeamWeaver.Moonshot.Tools do
  @moduledoc """
  Tool declaration helpers for Moonshot/Kimi Chat Completions.
  """

  alias BeamWeaver.Moonshot.Error
  alias BeamWeaver.OpenAI.ChatCompletions
  alias BeamWeaver.OpenAI.ToolCalling

  @allowed_types MapSet.new(["function", "builtin_function"])
  @function_name ~r/^[a-zA-Z0-9_-]{1,64}$/
  @max_tools 128

  @doc "Builds Kimi's built-in web-search tool declaration."
  @spec web_search(keyword() | map()) :: map()
  def web_search(opts \\ []) do
    opts = if is_map(opts), do: Map.to_list(opts), else: opts

    function =
      opts
      |> BeamWeaver.MapShape.stringify_entries()
      |> Map.put("name", "$web_search")

    %{"type" => "builtin_function", "function" => function}
  end

  @doc "Builds an OpenAI-compatible function tool declaration."
  @spec function(term(), keyword()) :: map()
  def function(tool, opts \\ []), do: ToolCalling.function(tool, opts)

  @doc "Converts tools to Moonshot Chat Completions declarations."
  @spec to_chat_tools([term()]) :: [map()]
  def to_chat_tools(tools) when is_list(tools), do: Enum.map(tools, &to_chat_tool/1)

  @doc "Converts one tool to a Moonshot Chat Completions declaration."
  @spec to_chat_tool(term()) :: map()
  def to_chat_tool(%{__struct__: _module} = tool), do: ChatCompletions.Messages.tool_to_openai(tool)

  def to_chat_tool(tool) when is_map(tool) do
    tool = BeamWeaver.MapShape.stringify_keys(tool)

    if builtin_tool?(tool) do
      tool
    else
      ChatCompletions.Messages.tool_to_openai(tool)
    end
  end

  def to_chat_tool(tool), do: ChatCompletions.Messages.tool_to_openai(tool)

  @doc false
  @spec validate_chat_tools([map()]) :: :ok | {:error, Error.t()}
  def validate_chat_tools(tools) when is_list(tools) do
    if length(tools) > @max_tools do
      {:error,
       Error.new(:invalid_request, "Moonshot supports at most 128 tools", %{
         provider: :moonshot,
         feature: :tools,
         count: length(tools),
         max: @max_tools
       })}
    else
      tools
      |> Enum.reduce_while(:ok, fn tool, :ok ->
        case validate_tool(tool) do
          :ok -> {:cont, :ok}
          {:error, error} -> {:halt, {:error, error}}
        end
      end)
    end
  end

  @doc false
  @spec web_search_tool?(map()) :: boolean()
  def web_search_tool?(tool) when is_map(tool) do
    tool = BeamWeaver.MapShape.stringify_keys(tool)
    get_in(tool, ["function", "name"]) == "$web_search"
  end

  def web_search_tool?(_tool), do: false

  defp builtin_tool?(%{"type" => "builtin_function"}), do: true
  defp builtin_tool?(_tool), do: false

  defp validate_tool(%{"type" => type} = tool) when is_binary(type) do
    cond do
      not MapSet.member?(@allowed_types, type) ->
        {:error,
         Error.new(:unsupported_feature, "Moonshot tool type is not supported", %{
           provider: :moonshot,
           api: :chat_completions,
           feature: :tools,
           unsupported: [type],
           supported: MapSet.to_list(@allowed_types) |> Enum.sort()
         })}

      type == "builtin_function" ->
        validate_builtin_tool(tool)

      true ->
        validate_function_tool(tool)
    end
  end

  defp validate_tool(tool) do
    {:error,
     Error.new(:invalid_request, "Moonshot tool declaration is invalid", %{
       provider: :moonshot,
       tool: inspect(tool)
     })}
  end

  defp validate_builtin_tool(tool) do
    case get_in(tool, ["function", "name"]) do
      "$web_search" ->
        :ok

      name ->
        {:error,
         Error.new(:unsupported_feature, "Moonshot built-in tool is not supported", %{
           provider: :moonshot,
           api: :chat_completions,
           feature: :tools,
           unsupported: [name],
           supported: ["$web_search"]
         })}
    end
  end

  defp validate_function_tool(tool) do
    function = tool["function"] || %{}
    name = function["name"]

    cond do
      not is_binary(name) or not Regex.match?(@function_name, name) ->
        {:error,
         Error.new(:invalid_request, "Moonshot function tool name is invalid", %{
           provider: :moonshot,
           name: name,
           pattern: Regex.source(@function_name)
         })}

      is_map(function["parameters"]) ->
        :ok

      true ->
        {:error,
         Error.new(:invalid_request, "Moonshot function tools require an input schema", %{
           provider: :moonshot,
           name: name
         })}
    end
  end
end
