defmodule BeamWeaver.Agent.Middleware.ToolSelection do
  @moduledoc """
  Filters and augments tools available to the model at runtime.
  """

  @behaviour BeamWeaver.Agent.Middleware

  alias BeamWeaver.Agent.ModelRequest
  alias BeamWeaver.Agent.ToolSet
  alias BeamWeaver.Core.ChatModel
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Models

  @default_system_prompt "Your goal is to select the most relevant tools for answering the user's query."

  defstruct allow: nil,
            deny: [],
            tags: [],
            metadata: %{},
            predicate: nil,
            tools: [],
            selector?: false,
            selector_model: nil,
            system_prompt: @default_system_prompt,
            max_tools: nil,
            always_include: [],
            descriptions: %{}

  def new(opts \\ []) do
    %__MODULE__{
      allow: Keyword.get(opts, :allow),
      deny: Keyword.get(opts, :deny, []),
      tags: Keyword.get(opts, :tags, []),
      metadata: Keyword.get(opts, :metadata, %{}),
      predicate: Keyword.get(opts, :predicate),
      tools: Keyword.get(opts, :tools, []),
      selector?: selector_opts?(opts),
      selector_model: normalize_model(Keyword.get(opts, :model)),
      system_prompt: Keyword.get(opts, :system_prompt, @default_system_prompt),
      max_tools: Keyword.get(opts, :max_tools),
      always_include: opts |> Keyword.get(:always_include, []) |> normalize_names(),
      descriptions:
        opts
        |> Keyword.get(:descriptions, %{})
        |> Map.new(fn {name, description} -> {to_string(name), to_string(description)} end)
    }
    |> validate!()
  end

  @impl true
  def name(_middleware), do: :tool_selection

  @impl true
  def tool_node_required?(%__MODULE__{tools: tools}), do: tools not in [nil, []]

  def wrap_model_call(%__MODULE__{} = middleware, %ModelRequest{} = request, handler) do
    dynamic_tools = resolve_tools(middleware.tools, request)

    tool_set =
      (request.tool_set || ToolSet.new(request.tools))
      |> ToolSet.add(dynamic_tools, source: :middleware)
      |> ToolSet.filter(&allowed?(middleware, &1, request))
      |> rewrite_descriptions(middleware.descriptions)

    with {:ok, tool_set} <- maybe_select_tools(middleware, tool_set, request) do
      request
      |> ModelRequest.override(tools: ToolSet.list(tool_set), tool_set: tool_set)
      |> handler.()
    end
  end

  defp resolve_tools(fun, request) when is_function(fun, 1), do: fun.(request) |> List.wrap()

  defp resolve_tools(fun, request) when is_function(fun, 2),
    do: fun.(request.state, request.runtime) |> List.wrap()

  defp resolve_tools(tools, _request), do: List.wrap(tools)

  defp rewrite_descriptions(%ToolSet{} = tool_set, descriptions) when map_size(descriptions) == 0,
    do: tool_set

  defp rewrite_descriptions(%ToolSet{} = tool_set, descriptions) do
    tool_set
    |> ToolSet.list()
    |> Enum.map(&rewrite_description(&1, descriptions))
    |> ToolSet.new(source: :middleware)
  end

  defp rewrite_description(tool, descriptions) do
    case Map.fetch(descriptions, Tool.name(tool)) do
      {:ok, description} -> put_description(tool, description)
      :error -> tool
    end
  end

  defp put_description(%Tool{} = tool, description), do: %{tool | description: description}

  defp put_description(tool, description) do
    Tool.from_function!(
      name: Tool.name(tool),
      description: description,
      input_schema: Tool.raw_input_schema(tool),
      injected: Tool.injected(tool),
      return_direct: Tool.return_direct(tool),
      response_format: Tool.response_format(tool),
      output_schema: Tool.output_schema(tool),
      handle_tool_error: Tool.handle_tool_error(tool),
      handle_validation_error: Tool.handle_validation_error(tool),
      parse_args: fn args -> Tool.parse_args(tool, args) end,
      concurrent: Tool.concurrent?(tool),
      max_result_chars: Tool.max_result_chars(tool),
      tags: Tool.tags(tool),
      metadata: Tool.metadata(tool),
      provider_opts: Tool.provider_opts(tool),
      handler: fn input, opts -> Tool.invoke(tool, input, Keyword.put(opts, :trace?, false)) end
    )
  end

  defp allowed?(%__MODULE__{} = middleware, tool, request) do
    name = Tool.name(tool)

    allow? =
      is_nil(middleware.allow) or name in Enum.map(List.wrap(middleware.allow), &to_string/1)

    deny? = name in Enum.map(List.wrap(middleware.deny), &to_string/1)
    tags? = middleware.tags == [] or Enum.any?(Tool.tags(tool), &(&1 in middleware.tags))

    metadata? =
      Enum.all?(middleware.metadata, fn {key, value} ->
        Map.get(Tool.metadata(tool), key) == value
      end)

    predicate? = is_nil(middleware.predicate) or middleware.predicate.(tool, request)

    allow? and not deny? and tags? and metadata? and predicate?
  end

  defp maybe_select_tools(%__MODULE__{selector?: false}, %ToolSet{} = tool_set, _request),
    do: {:ok, tool_set}

  defp maybe_select_tools(
         %__MODULE__{} = middleware,
         %ToolSet{} = tool_set,
         %ModelRequest{} = request
       ) do
    tools = ToolSet.list(tool_set)

    with :ok <- validate_always_include(middleware, tools),
         selectable_tools <- reject_always_include(tools, middleware.always_include) do
      if selectable_tools == [] do
        {:ok, tool_set}
      else
        select_tools(middleware, tool_set, selectable_tools, request)
      end
    end
  end

  defp select_tools(%__MODULE__{} = middleware, %ToolSet{} = tool_set, selectable_tools, request) do
    model = middleware.selector_model || request.model
    valid_names = Enum.map(selectable_tools, &Tool.name/1)

    messages = [
      Message.system(system_prompt(middleware)),
      last_user_message!(request.messages)
    ]

    opts = [response_format: selection_response_format(valid_names)]

    with {:ok, %Message{} = response} <- ChatModel.invoke(model, messages, opts),
         {:ok, selected_names} <- selected_tool_names(response),
         {:ok, selected_names} <- validate_selected_names(selected_names, valid_names),
         selected_names <- cap_and_dedupe(selected_names, middleware.max_tools),
         selected_tools <- tools_by_selection(selectable_tools, selected_names),
         always_tools <- tools_by_selection(ToolSet.list(tool_set), middleware.always_include) do
      {:ok, ToolSet.new(selected_tools ++ always_tools, source: :middleware)}
    else
      {:error, %Error{} = error} ->
        {:error, error}

      {:error, error} ->
        {:error, Error.new(:tool_selection_failed, "tool selection failed", %{reason: inspect(error)})}
    end
  rescue
    exception ->
      {:error,
       Error.new(:tool_selection_failed, Exception.message(exception), %{
         exception: inspect(exception.__struct__)
       })}
  end

  defp selection_response_format(valid_names) do
    %{
      name: "ToolSelectionResponse",
      schema: %{
        "type" => "object",
        "required" => ["tools"],
        "additionalProperties" => false,
        "properties" => %{
          "tools" => %{
            "type" => "array",
            "description" => "Tools to use. Place the most relevant tools first.",
            "items" => %{"type" => "string", "enum" => valid_names}
          }
        }
      }
    }
  end

  defp selected_tool_names(%Message{} = message) do
    with nil <- Map.get(message.metadata || %{}, :structured_response),
         nil <- Map.get(message.metadata || %{}, :parsed),
         nil <- selection_tool_call(message.tool_calls || []) do
      parse_text_selection(Message.text(message))
    else
      response ->
        selected_tool_names(response)
    end
  end

  defp selected_tool_names(%{"tools" => tools}) when is_list(tools),
    do: {:ok, Enum.map(tools, &to_string/1)}

  defp selected_tool_names(%{tools: tools}) when is_list(tools),
    do: {:ok, Enum.map(tools, &to_string/1)}

  defp selected_tool_names(other),
    do:
      {:error,
       Error.new(:invalid_tool_selection, "selection response must contain a tools list", %{
         response: inspect(other)
       })}

  defp selection_tool_call(calls) do
    Enum.find_value(calls, fn call ->
      name = Map.get(call, :name)

      if name == "ToolSelectionResponse" do
        Map.get(call, :args) ||
          Map.get(call, :arguments)
      end
    end)
  end

  defp parse_text_selection(text) when is_binary(text) do
    case BeamWeaver.JSON.decode(text) do
      {:ok, response} ->
        selected_tool_names(response)

      {:error, _error} ->
        tools =
          text
          |> String.split([",", "\n"], trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        if tools == [] do
          {:error, Error.new(:invalid_tool_selection, "selection response was empty")}
        else
          {:ok, tools}
        end
    end
  end

  defp validate_selected_names(selected_names, valid_names) do
    invalid = Enum.reject(selected_names, &(&1 in valid_names))

    if invalid == [] do
      {:ok, selected_names}
    else
      {:error,
       Error.new(:invalid_tool_selection, "model selected invalid tools", %{
         invalid_tools: invalid,
         valid_tools: valid_names
       })}
    end
  end

  defp cap_and_dedupe(names, max_tools) do
    names
    |> Enum.uniq()
    |> maybe_take(max_tools)
  end

  defp maybe_take(names, nil), do: names
  defp maybe_take(names, max_tools), do: Enum.take(names, max_tools)

  defp tools_by_selection(tools, names) do
    Enum.flat_map(names, fn name ->
      case Enum.find(tools, &(Tool.name(&1) == name)) do
        nil -> []
        tool -> [tool]
      end
    end)
  end

  defp reject_always_include(tools, always_include) do
    Enum.reject(tools, &(Tool.name(&1) in always_include))
  end

  defp validate_always_include(%__MODULE__{always_include: []}, _tools), do: :ok

  defp validate_always_include(%__MODULE__{always_include: always_include}, tools) do
    available = Enum.map(tools, &Tool.name/1)
    missing = Enum.reject(always_include, &(&1 in available))

    if missing == [] do
      :ok
    else
      {:error,
       Error.new(:invalid_tool_selection, "always_include tools are not available", %{
         missing_tools: missing,
         available_tools: available
       })}
    end
  end

  defp last_user_message!(messages) do
    case Enum.find(Enum.reverse(messages || []), &match?(%Message{role: :user}, &1)) do
      %Message{} = message -> message
      nil -> raise ArgumentError, "no user message found in model request"
    end
  end

  defp system_prompt(%__MODULE__{system_prompt: prompt, max_tools: nil}), do: prompt

  defp system_prompt(%__MODULE__{system_prompt: prompt, max_tools: max_tools}) do
    prompt <>
      "\nIMPORTANT: List the tool names in order of relevance, with the most relevant first. " <>
      "If you exceed the maximum number of tools, only the first #{max_tools} will be used."
  end

  defp selector_opts?(opts) do
    Enum.any?([:model, :system_prompt, :max_tools, :always_include], &Keyword.has_key?(opts, &1))
  end

  defp normalize_model(nil), do: nil
  defp normalize_model(model) when is_binary(model), do: Models.init_chat_model!(model)
  defp normalize_model(model), do: model

  defp normalize_names(names), do: names |> List.wrap() |> Enum.map(&to_string/1)

  defp validate!(%__MODULE__{max_tools: max_tools})
       when is_integer(max_tools) and max_tools < 0 do
    raise ArgumentError, "max_tools must be non-negative"
  end

  defp validate!(%__MODULE__{max_tools: max_tools})
       when not is_nil(max_tools) and not is_integer(max_tools) do
    raise ArgumentError, "max_tools must be an integer"
  end

  defp validate!(%__MODULE__{} = middleware), do: middleware
end
