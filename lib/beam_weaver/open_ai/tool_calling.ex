defmodule BeamWeaver.OpenAI.ToolCalling do
  @moduledoc """
  Builders for OpenAI Responses API tool declarations.
  """

  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Messages, as: CoreMessages
  alias BeamWeaver.Core.Tool
  alias BeamWeaver.OpenAI.Messages
  alias BeamWeaver.Tool.Renderer

  @doc """
  Converts BeamWeaver tools, OpenAI tool maps, and built-in tool declarations.
  """
  @spec to_openai_tools([term()]) :: [map()]
  def to_openai_tools(tools) when is_list(tools) do
    Enum.map(tools, &to_openai_tool/1)
  end

  @doc """
  Converts one tool declaration into the OpenAI request shape.
  """
  @spec to_openai_tool(term()) :: map()
  def to_openai_tool(%Tool{} = tool), do: Messages.tool_to_openai(tool)

  def to_openai_tool(tool) when is_atom(tool), do: Messages.tool_to_openai(tool)

  def to_openai_tool(%{__struct__: _module} = tool), do: Messages.tool_to_openai(tool)

  def to_openai_tool(tool) when is_map(tool) do
    tool
    |> stringify_keys()
    |> normalize_tool_map()
  end

  @doc """
  Builds an OpenAI function tool declaration from a BeamWeaver tool.
  """
  @spec function(term(), keyword()) :: map()
  def function(tool, opts \\ []) do
    if beamweaver_tool?(tool) do
      {render_opts, merge_opts} = Keyword.split(opts, [:strict])

      tool
      |> function_tool(render_opts)
      |> merge_options(merge_opts)
    else
      tool
      |> Messages.tool_to_openai()
      |> merge_options(opts)
    end
  end

  @doc """
  Builds a web search tool declaration.
  """
  @spec web_search(keyword()) :: map()
  def web_search(opts \\ []) do
    type = Keyword.get(opts, :type, "web_search_preview")

    build(type, Keyword.delete(opts, :type))
  end

  @doc """
  Builds a file search tool declaration.
  """
  @spec file_search([String.t()] | String.t(), keyword()) :: map()
  def file_search(vector_store_ids, opts \\ []) do
    "file_search"
    |> build(opts)
    |> Map.put("vector_store_ids", List.wrap(vector_store_ids))
  end

  @doc """
  Builds a code interpreter tool declaration.
  """
  @spec code_interpreter(term(), keyword()) :: map()
  def code_interpreter(container \\ %{"type" => "auto"}, opts \\ []) do
    "code_interpreter"
    |> build(opts)
    |> Map.put("container", BeamWeaver.MapShape.normalize_value(container))
  end

  @doc """
  Builds an image generation tool declaration.
  """
  @spec image_generation(keyword()) :: map()
  def image_generation(opts \\ []) do
    build("image_generation", opts)
  end

  @doc """
  Builds a remote MCP tool declaration.
  """
  @spec mcp(String.t(), String.t(), keyword()) :: map()
  def mcp(server_label, server_url, opts \\ [])
      when is_binary(server_label) and is_binary(server_url) do
    "mcp"
    |> build(opts)
    |> Map.put("server_label", server_label)
    |> Map.put("server_url", server_url)
  end

  @doc """
  Builds a custom tool declaration.
  """
  @spec custom(String.t(), keyword()) :: map()
  def custom(name, opts \\ []) when is_binary(name) do
    "custom"
    |> build(opts)
    |> Map.put("name", name)
  end

  @doc """
  Builds a tool search declaration.
  """
  @spec tool_search(keyword()) :: map()
  def tool_search(opts \\ []) do
    build("tool_search", opts)
  end

  @doc """
  Builds an OpenAI apply_patch built-in tool declaration.
  """
  @spec apply_patch(keyword()) :: map()
  def apply_patch(opts \\ []) do
    build("apply_patch", opts)
  end

  @doc """
  Builds native BeamWeaver few-shot messages for examples that include tool calls.

  This mirrors the behavior expected by OpenAI tool-calling examples while keeping
  the public value shape native: assistant messages carry `%Message{tool_calls: ...}`
  and tool outputs are normal tool-role messages.
  """
  @spec example_messages(String.t(), [term()], keyword()) :: [Message.t()]
  def example_messages(input, tool_calls, opts \\ [])
      when is_binary(input) and is_list(tool_calls) do
    calls =
      tool_calls
      |> Enum.with_index()
      |> Enum.map(fn {call, index} -> example_tool_call(call, index, opts) end)

    outputs =
      case Keyword.fetch(opts, :tool_outputs) do
        {:ok, outputs} -> List.wrap(outputs)
        :error -> List.duplicate("You have correctly called this tool.", length(calls))
      end

    messages = [
      Message.user(input),
      Message.assistant("", tool_calls: calls)
    ]

    messages =
      messages ++
        Enum.map(Enum.zip(outputs, calls), fn {output, call} ->
          Message.tool(output,
            tool_call_id: call.id,
            name: call.name
          )
        end)

    case Keyword.get(opts, :ai_response) do
      response when is_binary(response) and response != "" ->
        messages ++ [Message.assistant(response)]

      _missing ->
        messages
    end
  end

  @doc false
  @spec stringify_keys(map()) :: map()
  def stringify_keys(map) when is_map(map) do
    BeamWeaver.MapShape.stringify_keys(map)
  end

  defp build(type, opts) do
    opts
    |> BeamWeaver.MapShape.stringify_entries()
    |> Map.put("type", type)
  end

  defp merge_options(tool, opts) do
    Map.merge(tool, BeamWeaver.MapShape.stringify_entries(opts))
  end

  defp function_tool(%Tool{} = tool, render_opts), do: Renderer.openai_tool!(tool, render_opts)

  defp function_tool(%{__struct__: _module} = tool, render_opts),
    do: Renderer.openai_tool!(tool, render_opts)

  defp beamweaver_tool?(%Tool{}), do: true
  defp beamweaver_tool?(%{__struct__: module}), do: function_exported?(module, :name, 1)
  defp beamweaver_tool?(_tool), do: false

  defp normalize_tool_map(%{"type" => "function", "function" => function} = tool)
       when is_map(function) do
    tool
    |> Map.delete("function")
    |> Map.merge(stringify_keys(function))
  end

  defp normalize_tool_map(tool), do: tool

  defp example_tool_call(call, index, opts) do
    {name, args} = example_call_name_and_args(call)

    CoreMessages.tool_call(
      id: example_call_id(index, opts),
      name: name,
      args: BeamWeaver.MapShape.normalize_value(args)
    )
  end

  defp example_call_name_and_args({name, args}) when is_atom(name) or is_binary(name),
    do: {to_string(name), args}

  defp example_call_name_and_args(%{__struct__: module} = call) do
    args =
      call
      |> Map.from_struct()
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    {module |> Module.split() |> List.last(), args}
  end

  defp example_call_name_and_args(call) when is_map(call) do
    call = stringify_keys(call)
    name = call["name"] || call["tool"] || call["type"]
    args = call["args"] || call["arguments"] || call["input"] || call["parameters"] || %{}

    {to_string(name), args}
  end

  defp example_call_name_and_args(call), do: {call |> inspect() |> String.slice(0, 64), %{}}

  defp example_call_id(index, opts) do
    opts
    |> Keyword.get(:ids, [])
    |> Enum.at(index)
    |> case do
      nil -> "call_" <> Integer.to_string(System.unique_integer([:positive, :monotonic]), 36)
      id -> to_string(id)
    end
  end
end
