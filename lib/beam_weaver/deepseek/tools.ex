defmodule BeamWeaver.DeepSeek.Tools do
  @moduledoc """
  Tool declaration helpers for DeepSeek Chat Completions and Responses APIs.
  """

  alias BeamWeaver.Core.Error
  alias BeamWeaver.OpenAI.ChatCompletions
  alias BeamWeaver.OpenAI.ToolCalling
  alias BeamWeaver.Tool.Renderer

  @function_name ~r/^[A-Za-z0-9_-]{1,128}$/
  @max_tools 128
  @responses_tool_types ["function", "web_search"]

  @doc "Builds an OpenAI-compatible function tool declaration."
  @spec function(term(), keyword()) :: map()
  def function(tool, opts \\ []) do
    {render_opts, extra_opts} = Keyword.split(opts, [:strict])

    tool
    |> to_responses_tool(render_opts)
    |> Map.merge(BeamWeaver.MapShape.stringify_entries(extra_opts))
  end

  @doc "Builds a hosted web-search declaration for DeepSeek V4 Pro Responses. Flash does not execute this tool."
  @spec web_search(keyword()) :: map()
  def web_search(opts \\ []) do
    type = Keyword.get(opts, :type, "web_search")

    opts
    |> Keyword.delete(:type)
    |> BeamWeaver.MapShape.stringify_entries()
    |> Map.put("type", to_string(type))
  end

  @doc "Builds a Responses apply_patch client declaration; the application executes the patch and returns its result."
  @spec apply_patch(keyword()) :: map()
  def apply_patch(opts \\ []), do: ToolCalling.custom("apply_patch", opts)

  @doc "Converts tools to DeepSeek Chat Completions declarations."
  @spec to_chat_tools([term()]) :: [map()]
  def to_chat_tools(tools) when is_list(tools), do: Enum.map(tools, &to_chat_tool/1)

  # Like `to_chat_tool/1`, but a tool Chat Completions can't take, such as a
  # built-in tool of the Responses API, is an error instead of an exception.
  @doc false
  @spec render_chat_tool(term()) :: {:ok, map()} | {:error, Error.t()}
  def render_chat_tool(tool) when is_map(tool) and not is_struct(tool),
    do: tool |> BeamWeaver.MapShape.stringify_keys() |> ChatCompletions.Messages.Request.render_tool()

  def render_chat_tool(tool), do: {:ok, to_chat_tool(tool)}

  @doc "Converts one tool to a DeepSeek Chat Completions declaration."
  @spec to_chat_tool(term()) :: map()
  def to_chat_tool(%{__struct__: _module} = tool), do: native_chat_tool(tool)
  def to_chat_tool(tool) when is_atom(tool), do: native_chat_tool(tool)

  def to_chat_tool(tool) when is_map(tool) do
    tool
    |> BeamWeaver.MapShape.stringify_keys()
    |> ChatCompletions.Messages.tool_to_openai()
  end

  def to_chat_tool(tool), do: ChatCompletions.Messages.tool_to_openai(tool)

  def to_responses_tools(tools), do: Enum.map(tools, &to_responses_tool(&1, []))

  defp to_responses_tool(tool, opts) when is_struct(tool) or is_atom(tool),
    do: Renderer.openai_tool!(tool, Keyword.put(opts, :provider, :deepseek))

  defp to_responses_tool(tool, opts) do
    tool
    |> ToolCalling.to_openai_tool()
    |> Map.merge(BeamWeaver.MapShape.stringify_entries(opts))
  end

  defp native_chat_tool(tool),
    do: %{"type" => "function", "function" => to_responses_tool(tool, []) |> Map.delete("type")}

  @doc false
  @spec validate_chat_tools([map()]) :: :ok | {:error, Error.t()}
  def validate_chat_tools(tools) when is_list(tools) do
    with :ok <- validate_count(tools),
         :ok <- validate_each(tools, :chat_completions),
         do: validate_strict_set(tools)
  end

  @doc false
  @spec validate_responses_tools([map()]) :: :ok | {:error, Error.t()}
  def validate_responses_tools(tools) when is_list(tools) do
    with :ok <- validate_count(tools),
         :ok <- validate_each(tools, :responses),
         do: validate_unique_responses_names(tools)
  end

  defp error(type, message, details),
    do: {:error, Error.new(type, message, Enum.into(details, %{provider: :deepseek}))}

  defp validate_count(tools) do
    if length(tools) <= @max_tools,
      do: :ok,
      else:
        error(:invalid_request, "DeepSeek supports at most 128 tools",
          feature: :tools,
          count: length(tools),
          max: @max_tools
        )
  end

  defp validate_each(tools, api),
    do: Enum.find_value(tools, :ok, fn tool -> with :ok <- validate_tool(tool, api), do: nil end)

  defp validate_tool(%{"type" => "function", "function" => function}, :chat_completions)
       when is_map(function),
       do: validate_function(function, :chat_completions)

  defp validate_tool(%{"type" => type}, :chat_completions) do
    error(:unsupported_feature, "DeepSeek Chat Completions supports function tools only",
      api: :chat_completions,
      feature: :tools,
      unsupported: [type],
      supported: ["function"]
    )
  end

  defp validate_tool(%{"type" => "function"} = function, :responses),
    do: validate_function(function, :responses)

  defp validate_tool(%{"type" => "custom", "name" => "apply_patch"}, :responses), do: :ok

  defp validate_tool(%{"type" => type}, :responses) when is_binary(type) and type != "custom" and byte_size(type) > 0,
    do: :ok

  defp validate_tool(%{"type" => type} = tool, :responses) do
    error(:unsupported_feature, "DeepSeek Responses tool type is not supported",
      api: :responses,
      feature: :tools,
      unsupported: [type],
      tool: tool,
      supported: @responses_tool_types ++ ["custom:apply_patch"]
    )
  end

  defp validate_tool(tool, api),
    do: error(:invalid_request, "DeepSeek tool declaration is invalid", api: api, tool: inspect(tool))

  defp validate_function(function, api) do
    name = function["name"]
    parameters = function["parameters"]

    cond do
      not is_binary(name) or not Regex.match?(@function_name, name) ->
        error(:invalid_request, "DeepSeek function tool name is invalid",
          api: api,
          name: name,
          pattern: Regex.source(@function_name)
        )

      not is_nil(parameters) and not is_map(parameters) ->
        error(:invalid_request, "DeepSeek function parameters must be a JSON Schema object", api: api, name: name)

      function["strict"] not in [nil, true, false] ->
        error(:invalid_request, "DeepSeek function strict must be a boolean",
          api: api,
          name: name,
          strict: function["strict"]
        )

      true ->
        :ok
    end
  end

  defp validate_strict_set(tools) do
    functions =
      for %{"type" => "function", "function" => function} when is_map(function) <- tools,
          do: function

    if Enum.any?(functions, &(&1["strict"] == true)) and
         Enum.any?(functions, &(&1["strict"] != true)) do
      error(:invalid_request, "DeepSeek strict mode requires every function tool to be strict",
        api: :chat_completions,
        feature: :strict_tools
      )
    else
      :ok
    end
  end

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
        error(:invalid_request, "DeepSeek Responses tool names must be unique", api: :responses, names: duplicate_names)
    end
  end
end
