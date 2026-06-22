defmodule BeamWeaver.ZAI.Tools do
  @moduledoc """
  Tool declaration helpers for Z.ai Chat Completions.
  """

  alias BeamWeaver.OpenAI.ChatCompletions
  alias BeamWeaver.OpenAI.ToolCalling
  alias BeamWeaver.ZAI.Error

  @function_name ~r/^[a-zA-Z0-9_-]{1,64}$/
  @max_tools 128

  @doc "Builds an OpenAI-compatible function tool declaration."
  @spec function(term(), keyword()) :: map()
  def function(tool, opts \\ []), do: ToolCalling.function(tool, opts)

  @doc "Converts tools to Z.ai Chat Completions declarations."
  @spec to_chat_tools([term()]) :: [map()]
  def to_chat_tools(tools) when is_list(tools), do: Enum.map(tools, &to_chat_tool/1)

  @doc "Converts one tool to a Z.ai Chat Completions declaration."
  @spec to_chat_tool(term()) :: map()
  def to_chat_tool(%{__struct__: _module} = tool), do: ChatCompletions.Messages.tool_to_openai(tool)

  def to_chat_tool(tool) when is_map(tool) do
    tool
    |> BeamWeaver.MapShape.stringify_keys()
    |> ChatCompletions.Messages.tool_to_openai()
  end

  def to_chat_tool(tool), do: ChatCompletions.Messages.tool_to_openai(tool)

  @doc false
  @spec validate_chat_tools([map()]) :: :ok | {:error, Error.t()}
  def validate_chat_tools(tools) when is_list(tools) do
    if length(tools) > @max_tools do
      {:error,
       Error.new(:invalid_request, "Z.ai supports at most 128 tools", %{
         provider: :zai,
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

  defp validate_tool(%{"type" => "function"} = tool), do: validate_function_tool(tool)

  defp validate_tool(%{"type" => type}) do
    {:error,
     Error.new(:unsupported_feature, "Z.ai tool type is not supported", %{
       provider: :zai,
       api: :chat_completions,
       feature: :tools,
       unsupported: [type],
       supported: ["function"]
     })}
  end

  defp validate_tool(tool) do
    {:error,
     Error.new(:invalid_request, "Z.ai tool declaration is invalid", %{
       provider: :zai,
       tool: inspect(tool)
     })}
  end

  defp validate_function_tool(tool) do
    function = tool["function"] || %{}
    name = function["name"]

    cond do
      not is_binary(name) or not Regex.match?(@function_name, name) ->
        {:error,
         Error.new(:invalid_request, "Z.ai function tool name is invalid", %{
           provider: :zai,
           name: name,
           pattern: Regex.source(@function_name)
         })}

      is_map(function["parameters"]) ->
        :ok

      true ->
        {:error,
         Error.new(:invalid_request, "Z.ai function tools require an input schema", %{
           provider: :zai,
           name: name
         })}
    end
  end
end
