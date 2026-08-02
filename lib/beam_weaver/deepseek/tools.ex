defmodule BeamWeaver.DeepSeek.Tools do
  @moduledoc """
  Tool declaration helpers for DeepSeek Chat Completions and Responses APIs.
  """

  alias BeamWeaver.DeepSeek.Error
  alias BeamWeaver.OpenAI.ChatCompletions
  alias BeamWeaver.OpenAI.ToolCalling

  @chat_function_name ~r/^[A-Za-z0-9_-]{1,64}$/
  @responses_function_name ~r/^[A-Za-z0-9_-]{1,128}$/
  @max_tools 128
  @responses_tool_types ["function", "web_search", "web_search_2025_08_26"]

  @doc "Builds an OpenAI-compatible function tool declaration."
  @spec function(term(), keyword()) :: map()
  def function(tool, opts \\ []), do: ToolCalling.function(tool, opts)

  @doc "Builds a DeepSeek Responses web-search declaration."
  @spec web_search(keyword()) :: map()
  def web_search(opts \\ []) do
    type = Keyword.get(opts, :type, "web_search")

    opts
    |> Keyword.delete(:type)
    |> BeamWeaver.MapShape.stringify_entries()
    |> Map.put("type", to_string(type))
  end

  @doc "Builds the Responses API custom apply_patch declaration supported by DeepSeek."
  @spec apply_patch(keyword()) :: map()
  def apply_patch(opts \\ []), do: ToolCalling.custom("apply_patch", opts)

  @doc "Converts tools to DeepSeek Chat Completions declarations."
  @spec to_chat_tools([term()]) :: [map()]
  def to_chat_tools(tools) when is_list(tools), do: Enum.map(tools, &to_chat_tool/1)

  @doc "Converts one tool to a DeepSeek Chat Completions declaration."
  @spec to_chat_tool(term()) :: map()
  def to_chat_tool(%{__struct__: _module} = tool),
    do: ChatCompletions.Messages.tool_to_openai(tool)

  def to_chat_tool(tool) when is_map(tool) do
    tool
    |> BeamWeaver.MapShape.stringify_keys()
    |> ChatCompletions.Messages.tool_to_openai()
  end

  def to_chat_tool(tool), do: ChatCompletions.Messages.tool_to_openai(tool)

  @doc false
  @spec validate_chat_tools([map()]) :: :ok | {:error, Error.t()}
  def validate_chat_tools(tools) when is_list(tools) do
    with :ok <- validate_count(tools),
         :ok <- validate_each(tools, :chat_completions),
         :ok <- validate_strict_set(tools, :chat_completions) do
      :ok
    end
  end

  @doc false
  @spec validate_responses_tools([map()]) :: :ok | {:error, Error.t()}
  def validate_responses_tools(tools) when is_list(tools) do
    with :ok <- validate_count(tools),
         :ok <- validate_each(tools, :responses),
         :ok <- validate_unique_responses_names(tools) do
      :ok
    end
  end

  defp validate_count(tools) do
    if length(tools) <= @max_tools do
      :ok
    else
      {:error,
       Error.new(:invalid_request, "DeepSeek supports at most 128 tools", %{
         provider: :deepseek,
         feature: :tools,
         count: length(tools),
         max: @max_tools
       })}
    end
  end

  defp validate_each(tools, api) do
    Enum.reduce_while(tools, :ok, fn tool, :ok ->
      case validate_tool(tool, api) do
        :ok -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp validate_tool(%{"type" => "function", "function" => function}, :chat_completions)
       when is_map(function),
       do: validate_function(function, :chat_completions)

  defp validate_tool(%{"type" => type}, :chat_completions) do
    {:error,
     Error.new(:unsupported_feature, "DeepSeek Chat Completions supports function tools only", %{
       provider: :deepseek,
       api: :chat_completions,
       feature: :tools,
       unsupported: [type],
       supported: ["function"]
     })}
  end

  defp validate_tool(%{"type" => "function"} = function, :responses),
    do: validate_function(function, :responses)

  defp validate_tool(%{"type" => type}, :responses) when type in @responses_tool_types,
    do: :ok

  defp validate_tool(%{"type" => "custom", "name" => "apply_patch"}, :responses), do: :ok

  defp validate_tool(%{"type" => type} = tool, :responses) do
    {:error,
     Error.new(:unsupported_feature, "DeepSeek Responses tool type is not supported", %{
       provider: :deepseek,
       api: :responses,
       feature: :tools,
       unsupported: [type],
       tool: tool,
       supported: @responses_tool_types ++ ["custom:apply_patch"]
     })}
  end

  defp validate_tool(tool, api) do
    {:error,
     Error.new(:invalid_request, "DeepSeek tool declaration is invalid", %{
       provider: :deepseek,
       api: api,
       tool: inspect(tool)
     })}
  end

  defp validate_function(function, api) do
    name = function["name"]
    parameters = function["parameters"]
    name_pattern = function_name_pattern(api)

    cond do
      not is_binary(name) or not Regex.match?(name_pattern, name) ->
        {:error,
         Error.new(:invalid_request, "DeepSeek function tool name is invalid", %{
           provider: :deepseek,
           api: api,
           name: name,
           pattern: Regex.source(name_pattern)
         })}

      not is_nil(parameters) and not is_map(parameters) ->
        {:error,
         Error.new(:invalid_request, "DeepSeek function parameters must be a JSON Schema object", %{
           provider: :deepseek,
           api: api,
           name: name
         })}

      function["strict"] not in [nil, true, false] ->
        {:error,
         Error.new(:invalid_request, "DeepSeek function strict must be a boolean", %{
           provider: :deepseek,
           api: api,
           name: name,
           strict: function["strict"]
         })}

      true ->
        :ok
    end
  end

  defp validate_strict_set(tools, api) do
    functions = Enum.flat_map(tools, &function_payload(&1, api))

    if Enum.any?(functions, &(&1["strict"] == true)) and
         Enum.any?(functions, &(&1["strict"] != true)) do
      {:error,
       Error.new(:invalid_request, "DeepSeek strict mode requires every function tool to be strict", %{
         provider: :deepseek,
         api: api,
         feature: :strict_tools
       })}
    else
      :ok
    end
  end

  defp function_payload(%{"type" => "function", "function" => function}, :chat_completions)
       when is_map(function),
       do: [function]

  defp function_payload(%{"type" => "function"} = function, :responses), do: [function]
  defp function_payload(_tool, _api), do: []

  defp validate_unique_responses_names(tools) do
    names =
      Enum.flat_map(tools, fn
        %{"type" => "function", "name" => name} when is_binary(name) -> [name]
        %{"type" => "custom", "name" => name} when is_binary(name) -> [name]
        _tool -> []
      end)

    duplicates = names -- Enum.uniq(names)

    case Enum.uniq(duplicates) do
      [] ->
        :ok

      duplicate_names ->
        {:error,
         Error.new(:invalid_request, "DeepSeek Responses tool names must be unique", %{
           provider: :deepseek,
           api: :responses,
           names: duplicate_names
         })}
    end
  end

  defp function_name_pattern(:chat_completions), do: @chat_function_name
  defp function_name_pattern(:responses), do: @responses_function_name
end
