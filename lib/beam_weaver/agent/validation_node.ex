defmodule BeamWeaver.Agent.ValidationNode do
  @moduledoc """
  Graph node that validates tool calls without executing the tools. An agent
  declared with `validate_tools true` runs it before its tools node.

  The node accepts normal graph state (`%{messages: [...]}`) or a raw message
  list. It returns tool messages with validated arguments or validation errors.
  """

  alias BeamWeaver.Agent.ToolNode.Execution
  alias BeamWeaver.Agent.ToolNode.Input
  alias BeamWeaver.Agent.ToolSet
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Tool

  defstruct schemas: %{}, format_error: nil, success: :message

  @type t :: %__MODULE__{
          schemas: %{String.t() => map()},
          format_error: nil | function(),
          success: :message | :silent
        }

  @spec new([term()], keyword()) :: t()
  def new(schemas_or_tools, opts \\ []) when is_list(schemas_or_tools) do
    %__MODULE__{
      schemas: Map.new(schemas_or_tools, &schema_entry!/1),
      format_error: Keyword.get(opts, :format_error),
      success: Keyword.get(opts, :success, :message)
    }
  end

  @spec invoke(t(), term(), term()) :: map() | [Message.t()] | {:error, Error.t()}
  def invoke(%__MODULE__{} = node, input, _runtime \\ nil) do
    with {:ok, tool_calls, output_shape} <- extract_tool_calls(input) do
      node = apply_tool_set(node, input)

      messages =
        tool_calls
        |> Task.async_stream(&validate_call(node, normalize_tool_call(&1)),
          ordered: true,
          on_timeout: :kill_task
        )
        |> Enum.zip(tool_calls)
        |> Enum.map(fn
          {{:ok, message}, _call} -> message
          {{:exit, reason}, call} -> exited_call_message(call, reason)
        end)
        |> Enum.reject(&is_nil/1)

      if output_shape == :state, do: %{messages: messages}, else: messages
    end
  end

  # In an agent, the tools the model was offered on its latest call, as the
  # tools node runs them.
  defp apply_tool_set(%__MODULE__{} = node, input) do
    case {ToolSet.from_state(input), ToolSet.saved_names(input)} do
      {%ToolSet{} = tool_set, _names} ->
        %{node | schemas: Map.new(ToolSet.list(tool_set), &schema_entry!/1)}

      {nil, names} when is_list(names) ->
        %{node | schemas: Map.take(node.schemas, names)}

      {nil, nil} ->
        node
    end
  end

  defp schema_entry!({name, schema}) when is_binary(name) and is_map(schema), do: {name, schema}

  defp schema_entry!(%Tool{} = tool), do: {Tool.name(tool), Tool.input_schema(tool)}

  defp schema_entry!(tool) when is_map(tool) and not is_struct(tool) do
    name = Map.get(tool, :name) || Map.get(tool, "name")

    schema =
      Map.get(tool, :input_schema) || Map.get(tool, "input_schema") || Map.get(tool, :schema) ||
        Map.get(tool, "schema")

    if is_binary(name) and is_map(schema) do
      {name, schema}
    else
      raise ArgumentError, "validation schema maps must include name and schema/input_schema"
    end
  end

  defp schema_entry!(tool) do
    {Tool.name(tool), Tool.input_schema(tool)}
  rescue
    _exception ->
      reraise ArgumentError,
              [message: "validation node expected tools or {name, schema} entries"],
              __STACKTRACE__
  end

  defp extract_tool_calls(%{messages: messages}) when is_list(messages),
    do: extract_from_messages(messages, :state)

  defp extract_tool_calls(%{"messages" => messages}) when is_list(messages),
    do: extract_from_messages(messages, :state)

  defp extract_tool_calls([%Message{} | _rest] = messages),
    do: extract_from_messages(messages, :list)

  defp extract_tool_calls(_input) do
    {:error, Error.new(:invalid_validation_node_input, "validation node expected messages")}
  end

  defp extract_from_messages(messages, shape) do
    messages
    |> Enum.reverse()
    |> Enum.find(&match?(%Message{role: :assistant}, &1))
    |> case do
      %Message{tool_calls: tool_calls} when is_list(tool_calls) -> {:ok, tool_calls, shape}
      _other -> {:ok, [], shape}
    end
  end

  defp exited_call_message(raw_call, reason) do
    {id, name} = tool_call_identity(raw_call)

    Message.tool("Tool validation failed: #{inspect(reason)}",
      tool_call_id: id,
      name: name,
      metadata: %{status: "error", error_type: :validation_node_crash, is_error: true}
    )
  end

  defp tool_call_identity(raw_call) do
    call = normalize_tool_call(raw_call)
    {call.id, call.name}
  rescue
    _exception -> {nil, nil}
  end

  defp validate_call(%__MODULE__{} = node, call) do
    with {:ok, schema} <- fetch_schema(node, call),
         :ok <- Tool.validate_input(schema, call.args) do
      valid_call_message(node, call)
    else
      {:error, %Error{} = error} ->
        Message.tool(format_error(node, error, call),
          tool_call_id: call.id,
          name: call.name,
          metadata: %{status: "error", error_type: error.type, is_error: true}
        )
    end
  end

  defp valid_call_message(%__MODULE__{success: :silent}, _call), do: nil

  defp valid_call_message(%__MODULE__{}, call) do
    Message.tool(BeamWeaver.JSON.encode_or_inspect(call.args),
      tool_call_id: call.id,
      name: call.name,
      metadata: %{status: "success"}
    )
  end

  defp fetch_schema(%__MODULE__{schemas: schemas}, call) do
    case Map.fetch(schemas, call.name) do
      {:ok, schema} ->
        {:ok, schema}

      :error ->
        {:error, Error.new(:unknown_tool, "tool schema is not registered", %{tool: call.name})}
    end
  end

  defp normalize_tool_call(call) do
    %{
      id: Input.tool_call_id(call),
      name: Input.tool_call_name(call),
      args: Input.tool_call_args(call)
    }
  end

  defp format_error(%__MODULE__{format_error: formatter}, %Error{} = error, call)
       when is_function(formatter, 2) do
    formatter.(error, call)
  end

  defp format_error(%__MODULE__{format_error: formatter}, %Error{} = error, _call)
       when is_function(formatter, 1) do
    formatter.(error)
  end

  defp format_error(%__MODULE__{format_error: nil}, %Error{} = error, call) do
    hidden = MapSet.new(~w(state store runtime tool_runtime context config checkpointer tool_message))

    ["Tool validation error: #{error.message}"]
    |> Execution.maybe_append("Args", Execution.sanitize_value(call.args, hidden))
    |> Execution.maybe_append("Details", Execution.sanitize_value(error.details, hidden))
    |> Enum.join(". ")
  end
end
