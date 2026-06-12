defmodule BeamWeaver.Graph.Nodes.ValidationNode do
  @moduledoc """
  Graph node that validates tool calls without executing the tools.

  The node accepts normal graph state (`%{messages: [...]}`) or a raw message
  list. It returns tool messages with validated arguments or validation errors.
  """

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
        |> Task.async_stream(&validate_call(node, normalize_tool_call(&1)), ordered: true)
        |> Enum.map(fn {:ok, message} -> message end)
        |> Enum.reject(&is_nil/1)

      if output_shape == :state, do: %{messages: messages}, else: messages
    end
  end

  defp apply_tool_set(%__MODULE__{} = node, input) do
    case ToolSet.from_state(input) do
      %ToolSet{} = tool_set ->
        %{node | schemas: Map.new(ToolSet.list(tool_set), &schema_entry!/1)}

      nil ->
        node
    end
  end

  defp schema_entry!({name, schema}) when is_binary(name) and is_map(schema), do: {name, schema}

  defp schema_entry!(%Tool{} = tool), do: {Tool.name(tool), Tool.input_schema(tool)}

  defp schema_entry!(tool) when is_map(tool) do
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
    |> Enum.find(fn
      %Message{role: :assistant} -> true
      _other -> false
    end)
    |> case do
      %Message{tool_calls: tool_calls} when is_list(tool_calls) -> {:ok, tool_calls, shape}
      _other -> {:ok, [], shape}
    end
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
    Message.tool(format_valid_args(call.args),
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
      id: tool_call_id(call),
      name: tool_call_name(call),
      args: tool_call_args(call)
    }
  end

  defp tool_call_id(call) do
    get_value(call, :call_id) || get_value(call, :tool_call_id) || get_value(call, :id)
  end

  defp tool_call_name(call) do
    get_value(call, :name) ||
      nested_value(call, [:function, :name]) ||
      nested_value(call, ["function", "name"])
  end

  defp tool_call_args(call) do
    args =
      get_value(call, :args) ||
        get_value(call, :arguments) ||
        nested_value(call, [:function, :arguments]) ||
        nested_value(call, ["function", "arguments"]) ||
        %{}

    decode_args(args)
  end

  defp get_value(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))

  defp nested_value(map, keys) when is_map(map) do
    Enum.reduce_while(keys, map, fn key, acc ->
      if is_map(acc) do
        case Map.fetch(acc, key) do
          {:ok, value} ->
            {:cont, value}

          :error ->
            case Map.fetch(acc, to_string(key)) do
              {:ok, value} -> {:cont, value}
              :error -> {:halt, nil}
            end
        end
      else
        {:halt, nil}
      end
    end)
  end

  defp decode_args(args) when is_binary(args) do
    case BeamWeaver.JSON.decode(args) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _other -> %{"input" => args}
    end
  end

  defp decode_args(args) when is_map(args), do: args
  defp decode_args(_args), do: %{}

  defp format_valid_args(args) do
    case BeamWeaver.JSON.encode(args) do
      {:ok, json} -> json
      {:error, _error} -> inspect(args)
    end
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
    hidden = hidden_arg_names(error.details)
    args = sanitize_value(call.args, hidden)
    details = sanitize_value(error.details, hidden)

    ["Tool validation error: #{error.message}"]
    |> maybe_append("Args", args)
    |> maybe_append("Details", details)
    |> Enum.join(". ")
  end

  defp maybe_append(parts, _label, value) when value in [%{}, [], nil], do: parts
  defp maybe_append(parts, label, value), do: parts ++ ["#{label}: #{inspect(value)}"]

  defp hidden_arg_names(_details) do
    ~w(state store runtime tool_runtime context config checkpointer tool_message)
  end

  defp sanitize_value(%{__struct__: _module} = value, _hidden), do: inspect(value)

  defp sanitize_value(value, hidden) when is_map(value) do
    value
    |> Enum.reject(fn {key, _value} -> to_string(key) in hidden end)
    |> Map.new(fn {key, value} -> {key, sanitize_value(value, hidden)} end)
  end

  defp sanitize_value(values, hidden) when is_list(values) do
    values
    |> Enum.reject(fn value -> is_binary(value) and value in hidden end)
    |> Enum.map(&sanitize_value(&1, hidden))
  end

  defp sanitize_value(value, _hidden), do: value
end
