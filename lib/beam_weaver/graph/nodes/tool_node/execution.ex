defmodule BeamWeaver.Graph.Nodes.ToolNode.Execution do
  @moduledoc false

  alias BeamWeaver.Agent.Middleware
  alias BeamWeaver.Agent.ToolCallRequest
  alias BeamWeaver.Agent.ToolSet
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Core.ToolRuntime
  alias BeamWeaver.Graph.Command
  alias BeamWeaver.Graph.Nodes.ToolNode.Input
  alias BeamWeaver.Graph.Nodes.ToolNode.Output
  alias BeamWeaver.Stream.Events
  alias BeamWeaver.Tracing

  def invoke(node, input, runtime) do
    with {:ok, tool_calls, output_shape} <- Input.extract(input, node.messages_key) do
      node = apply_tool_set(node, input)
      calls = Enum.map(tool_calls, &Input.normalize_call/1)
      request_state = Input.request_state(input, runtime)

      results =
        calls
        |> Enum.with_index()
        |> execution_groups(node)
        |> Enum.flat_map(&execute_group(&1, node, request_state, runtime))
        |> Enum.sort_by(fn {index, _call, _result} -> index end)
        |> Enum.map(fn {_index, call, result} -> normalize_task_result(node, call, result) end)
        |> flatten_outputs()

      case Enum.find(results, &match?({:error, %Error{}}, &1)) do
        {:error, %Error{} = error} ->
          {:error, error}

        nil ->
          Output.build(results, output_shape)
      end
    end
  end

  defp execution_groups(indexed_calls, node) do
    {groups, concurrent} =
      Enum.reduce(indexed_calls, {[], []}, fn {call, _index} = entry, {groups, concurrent} ->
        if tool_concurrent?(node, call) do
          {groups, [entry | concurrent]}
        else
          groups = prepend_concurrent_group(groups, concurrent)
          {[{:sequential, [entry]} | groups], []}
        end
      end)

    groups
    |> prepend_concurrent_group(concurrent)
    |> Enum.reverse()
  end

  defp prepend_concurrent_group(groups, []), do: groups

  defp prepend_concurrent_group(groups, concurrent),
    do: [{:concurrent, Enum.reverse(concurrent)} | groups]

  defp execute_group({:concurrent, indexed_calls}, node, request_state, runtime) do
    indexed_calls
    |> async_stream_tools(
      runtime,
      fn {call, index} ->
        call = Map.put(call, :index, index)
        {index, call, execute_call(node, call, request_state, runtime)}
      end,
      ordered: true,
      timeout: node.timeout,
      on_timeout: :kill_task
    )
    |> Enum.zip(indexed_calls)
    |> Enum.map(fn
      {{:ok, {index, call, value}}, _entry} -> {index, call, {:ok, value}}
      {{:exit, reason}, {call, index}} -> {index, call, {:exit, reason}}
    end)
  end

  defp execute_group({:sequential, indexed_calls}, node, request_state, runtime) do
    execute_group({:concurrent, indexed_calls}, node, request_state, runtime)
  end

  defp async_stream_tools(indexed_calls, runtime, fun, opts) do
    context = Tracing.capture_context()

    traced_fun = fn entry ->
      Tracing.attach_context(context, fn -> fun.(entry) end)
    end

    case task_supervisor(runtime) do
      nil ->
        Task.async_stream(indexed_calls, traced_fun, opts)

      supervisor ->
        Task.Supervisor.async_stream_nolink(supervisor, indexed_calls, traced_fun, opts)
    end
  end

  defp task_supervisor(%{task_supervisor: supervisor}) when not is_nil(supervisor),
    do: supervisor

  defp task_supervisor(%{execution: execution}) do
    case runtime_value(execution, :task_supervisor) do
      nil -> runtime_value(execution, "task_supervisor")
      supervisor -> supervisor
    end
  end

  defp task_supervisor(_runtime), do: nil

  defp tool_concurrent?(node, call) do
    case Map.get(node.tools, call.name) do
      nil -> true
      tool -> Tool.concurrent?(tool)
    end
  end

  defp execute_call(node, call, state, runtime) do
    request = %ToolCallRequest{
      tool_call: call,
      tool: Map.get(node.tools, call.name),
      tool_set: ToolSet.new(Map.values(node.tools)),
      state: state,
      runtime: runtime
    }

    emit_tool_started(runtime, call)

    result =
      node.wrap_tool_call
      |> Enum.filter(&Middleware.hook?(&1, :wrap_tool_call))
      |> Enum.reverse()
      |> Enum.reduce(&execute_tool_request(node, &1), fn middleware, inner ->
        fn request ->
          Middleware.call_wrapper(middleware, :wrap_tool_call, request, inner)
        end
      end)
      |> then(fn handler -> handler.(request) end)
      |> normalize_wrapped_tool_result(node, call)

    emit_tool_terminal(runtime, call, result)
    result
  rescue
    exception ->
      error =
        Error.new(:tool_middleware_exception, Exception.message(exception), %{
          tool: call.name,
          tool_call_id: call.id,
          exception: inspect(exception.__struct__)
        })

      result = handle_tool_error(node, call, error)
      emit_tool_terminal(runtime, call, result)
      result
  catch
    kind, reason ->
      error =
        Error.new(:tool_middleware_exit, "tool middleware exited", %{
          tool: call.name,
          tool_call_id: call.id,
          kind: kind,
          reason: inspect(reason)
        })

      result = handle_tool_error(node, call, error)
      emit_tool_terminal(runtime, call, result)
      result
  end

  defp execute_tool_request(node, %ToolCallRequest{} = request) do
    call = Input.normalize_call(request.tool_call)
    tool = request.tool || Map.get(node.tools, call.name)

    if is_nil(tool) do
      handle_tool_error(
        node,
        call,
        Error.new(:unknown_tool, "tool is not registered", %{tool: call.name})
      )
    else
      tool_runtime = tool_runtime(node, tool, call, request.state, request.runtime)

      case inject_tool_args(tool, call.args, call, request.state, request.runtime, tool_runtime) do
        {:ok, args} ->
          tool_runtime = %{tool_runtime | args: args}

          case Tool.invoke(tool, args,
                 tool_call_id: call.id,
                 tool_runtime: tool_runtime,
                 trace_input: call.args,
                 trace_metadata: tool_call_trace_metadata(call)
               ) do
            {:ok, value} ->
              case Output.normalize(value, call) do
                {:ok, output} -> Output.return_direct(output, tool)
                {:error, %Error{} = error} -> handle_tool_error(node, call, error)
              end

            {:error, %Error{} = error} ->
              handle_tool_error(node, call, error)
          end

        {:error, %Error{} = error} ->
          handle_tool_error(node, call, error)
      end
    end
  end

  defp normalize_wrapped_tool_result({:ok, result}, _node, _call), do: result

  defp normalize_wrapped_tool_result({:error, %Error{} = error}, _node, _call),
    do: {:error, error}

  defp normalize_wrapped_tool_result(result, _node, _call), do: result

  defp tool_call_trace_metadata(call) do
    %{}
    |> maybe_put(:call_id, Map.get(call, :call_id))
    |> maybe_put(:id, Map.get(call, :id))
    |> maybe_put(:provider_id, Map.get(call, :provider_id))
    |> maybe_put(:tool_call_index, Map.get(call, :index))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp emit_tool_started(%{stream_writer: writer}, call) when is_function(writer, 1) do
    writer.(%Events.ToolStart{
      tool_call_id: call.id,
      tool_name: call.name,
      input: call.args
    })
  end

  defp emit_tool_started(_runtime, _call), do: :ok

  defp emit_tool_terminal(%{stream_writer: writer}, call, result) when is_function(writer, 1) do
    writer.(terminal_tool_event(call, result))
  end

  defp emit_tool_terminal(_runtime, _call, _result), do: :ok

  defp terminal_tool_event(call, {:error, %Error{} = error}) do
    %Events.ToolError{
      tool_call_id: call.id,
      message: error.message,
      error_type: error.type
    }
  end

  defp terminal_tool_event(call, %Message{metadata: %{status: "error"}} = message) do
    %Events.ToolError{
      tool_call_id: call.id,
      message: message.content,
      error_type: Map.get(message.metadata, :error_type)
    }
  end

  defp terminal_tool_event(call, result) do
    %Events.ToolFinish{
      tool_call_id: call.id,
      output: tool_event_output(result)
    }
  end

  defp tool_event_output(%Message{role: :tool, content: content}), do: content
  defp tool_event_output(%Command{} = command), do: command

  defp tool_event_output(outputs) when is_list(outputs),
    do: Enum.map(outputs, &tool_event_output/1)

  defp tool_event_output(output), do: output

  defp normalize_task_result(node, call, {:ok, %Message{} = message}),
    do: truncate_tool_output(message, node, call)

  defp normalize_task_result(_node, _call, {:ok, %Command{} = command}), do: command

  defp normalize_task_result(node, call, {:ok, outputs}) when is_list(outputs),
    do: truncate_tool_output(outputs, node, call)

  defp normalize_task_result(
         %{handle_errors: false},
         _call,
         {:ok, {:error, %Error{} = error}}
       ),
       do: {:error, error}

  defp normalize_task_result(node, call, {:ok, {:error, %Error{} = error}}) do
    handle_tool_error(node, call, error)
  end

  defp normalize_task_result(node, call, {:ok, other}) do
    error =
      Error.new(:invalid_tool_middleware_result, "tool middleware returned an invalid result", %{
        tool: call.name,
        tool_call_id: call.id,
        result: inspect(other)
      })

    handle_tool_error(node, call, error)
  end

  defp normalize_task_result(node, call, {:exit, :timeout}) do
    error = tool_timeout_error(node, call)
    handle_tool_error(node, call, error)
  end

  defp normalize_task_result(node, call, {:exit, reason}) do
    error =
      Error.new(:tool_task_exit, "tool task exited", %{
        tool: call.name,
        tool_call_id: call.id,
        reason: inspect(reason)
      })

    handle_tool_error(node, call, error)
  end

  defp handle_tool_error(node, call, %Error{} = error) do
    if handle_error?(node, error) do
      node
      |> tool_error_message(call, error)
      |> truncate_tool_output(node, call)
    else
      {:error, error}
    end
  end

  defp tool_error_message(node, call, %Error{} = error) do
    Message.tool(format_error(node, error, call),
      tool_call_id: call.id,
      name: call.name,
      metadata: %{status: "error", error_type: error.type}
    )
  end

  defp truncate_tool_output(%Message{role: :tool, content: content} = message, node, call)
       when is_binary(content) do
    case max_result_chars(node, call) do
      :unlimited ->
        message

      max_chars ->
        %{message | content: truncate_text(content, max_chars)}
    end
  end

  defp truncate_tool_output(outputs, node, call) when is_list(outputs) do
    Enum.map(outputs, &truncate_tool_output(&1, node, call))
  end

  defp truncate_tool_output(output, _node, _call), do: output

  defp max_result_chars(node, call) do
    case Map.get(node.tools, call.name) do
      nil -> :unlimited
      tool -> Tool.max_result_chars(tool)
    end
  end

  defp truncate_text(text, max_chars) when is_integer(max_chars) and max_chars > 0 do
    original_chars = String.length(text)

    if original_chars <= max_chars do
      text
    else
      suffix = truncation_suffix(original_chars - max_chars)

      if String.length(suffix) >= max_chars do
        String.slice(suffix, 0, max_chars)
      else
        visible = max_chars - String.length(suffix)
        String.slice(text, 0, visible) <> truncation_suffix(original_chars - visible)
      end
    end
  end

  defp truncation_suffix(omitted), do: "\n\n[truncated #{omitted} chars]"

  defp handle_error?(%{handle_errors: false}, _error), do: false
  defp handle_error?(%{handle_errors: true}, _error), do: true
  defp handle_error?(%{handle_errors: message}, _error) when is_binary(message), do: true
  defp handle_error?(%{handle_errors: formatter}, _error) when is_function(formatter), do: true

  defp handle_error?(%{handle_errors: error_type}, %Error{type: type}) when is_atom(error_type),
    do: type == error_type

  defp handle_error?(%{handle_errors: error_types}, %Error{type: type})
       when is_list(error_types),
       do: type in error_types

  defp handle_error?(_node, _error), do: false

  defp inject_tool_args(tool, args, call, state, runtime, tool_runtime) do
    tool
    |> Tool.injected()
    |> Enum.reduce_while({:ok, args}, fn {arg, source}, {:ok, acc} ->
      case injected_value(source, call, state, runtime, tool_runtime) do
        {:ok, value} ->
          {:cont, {:ok, Map.put(acc, arg, value)}}

        {:error, %Error{} = error} ->
          {:halt, {:error, error}}
      end
    end)
  end

  defp tool_runtime(node, tool, call, state, runtime) do
    ToolRuntime.new(
      tool: tool,
      tool_name: call.name,
      tool_call: call,
      tool_call_id: call.id,
      args: call.args,
      state: state,
      runtime: runtime,
      tools: Map.values(node.tools)
    )
  end

  defp apply_tool_set(node, input) do
    case ToolSet.from_state(input) do
      %ToolSet{} = tool_set -> %{node | tools: tool_set.tools}
      nil -> node
    end
  end

  defp flatten_outputs(outputs) do
    Enum.flat_map(outputs, fn
      output when is_list(output) -> output
      output -> [output]
    end)
  end

  defp injected_value(:state, _call, state, _runtime, _tool_runtime), do: {:ok, state}

  defp injected_value({:state, field_or_path}, _call, state, _runtime, _tool_runtime),
    do: {:ok, get_state_field(state, field_or_path)}

  defp injected_value(:store, _call, _state, runtime, _tool_runtime),
    do: {:ok, runtime_value(runtime, :store)}

  defp injected_value(:runtime, _call, _state, runtime, _tool_runtime), do: {:ok, runtime}

  defp injected_value(:tool_runtime, _call, _state, _runtime, tool_runtime),
    do: {:ok, tool_runtime}

  defp injected_value(:tool_call_id, call, _state, _runtime, _tool_runtime),
    do: {:ok, call.id}

  defp injected_value(:context, _call, _state, runtime, _tool_runtime),
    do: {:ok, runtime_value(runtime, :context)}

  defp injected_value(:config, _call, _state, runtime, _tool_runtime),
    do: {:ok, runtime_value(runtime, :config)}

  defp injected_value(:checkpointer, _call, _state, runtime, _tool_runtime),
    do: {:ok, runtime_value(runtime, :checkpointer)}

  defp injected_value(source, _call, _state, _runtime, _tool_runtime) do
    {:error,
     Error.new(:invalid_tool, "tool injected arg source is not supported", %{
       source: inspect(source)
     })}
  end

  defp runtime_value(nil, _field), do: nil
  defp runtime_value(runtime, field) when is_map(runtime), do: Map.get(runtime, field)

  defp get_state_field(state, path) when is_list(path) do
    Enum.reduce_while(path, state, fn field, acc ->
      case get_state_field(acc, field) do
        nil -> {:halt, nil}
        value -> {:cont, value}
      end
    end)
  end

  defp get_state_field(state, field) when is_map(state) do
    cond do
      Map.has_key?(state, field) ->
        Map.fetch!(state, field)

      is_atom(field) and Map.has_key?(state, Atom.to_string(field)) ->
        Map.fetch!(state, Atom.to_string(field))

      is_binary(field) ->
        state
        |> Map.keys()
        |> Enum.find(&(to_string(&1) == field))
        |> case do
          nil -> nil
          key -> Map.fetch!(state, key)
        end

      true ->
        nil
    end
  end

  defp get_state_field(_state, _field), do: nil

  defp format_error(%{handle_errors: message}, _error, _call) when is_binary(message),
    do: message

  defp format_error(%{handle_errors: formatter}, error, _call) when is_function(formatter, 1),
    do: formatter.(error)

  defp format_error(node, %Error{} = error, call) do
    hidden = hidden_arg_names(node, call)
    args = sanitize_value(call.args || %{}, hidden)
    details = sanitize_value(error.details || %{}, hidden)

    ["Tool error: #{error.message}"]
    |> maybe_append("Args", args)
    |> maybe_append("Details", details)
    |> Enum.join(". ")
  end

  defp maybe_append(parts, _label, value) when value in [%{}, [], nil], do: parts
  defp maybe_append(parts, label, value), do: parts ++ ["#{label}: #{inspect(value)}"]

  defp hidden_arg_names(node, call) do
    base =
      ~w(state store runtime tool_runtime context config checkpointer tool_message)
      |> MapSet.new()

    case Map.get(node.tools, call.name) do
      nil ->
        base

      tool ->
        tool
        |> Tool.injected()
        |> Map.keys()
        |> Enum.map(&to_string/1)
        |> Enum.reduce(base, &MapSet.put(&2, &1))
    end
  end

  defp sanitize_value(%{__struct__: _module} = value, _hidden), do: inspect(value)

  defp sanitize_value(value, hidden) when is_map(value) do
    value
    |> Enum.reject(fn {key, _value} -> MapSet.member?(hidden, to_string(key)) end)
    |> Map.new(fn {key, value} -> {key, sanitize_value(value, hidden)} end)
  end

  defp sanitize_value(values, hidden) when is_list(values) do
    values
    |> Enum.reject(fn value -> is_binary(value) and MapSet.member?(hidden, value) end)
    |> Enum.map(&sanitize_value(&1, hidden))
  end

  defp sanitize_value(value, _hidden), do: value

  defp tool_timeout_error(node, call) do
    Error.new(:tool_timeout, "tool timed out", %{
      tool: call.name,
      tool_call_id: call.id,
      timeout: node.timeout
    })
  end
end
