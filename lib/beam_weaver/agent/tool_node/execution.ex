defmodule BeamWeaver.Agent.ToolNode.Execution do
  @moduledoc false

  import BeamWeaver.MapShape, only: [put_present: 3]

  alias BeamWeaver.Agent.Middleware
  alias BeamWeaver.Agent.ToolCallRequest
  alias BeamWeaver.Agent.ToolNode.Input
  alias BeamWeaver.Agent.ToolNode.Output
  alias BeamWeaver.Agent.ToolSet
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Core.ToolRuntime
  alias BeamWeaver.Graph.Command
  alias BeamWeaver.Graph.Execution.Scratchpad
  alias BeamWeaver.Stream.Events
  alias BeamWeaver.Tracing

  @signals [:beam_weaver_graph_interrupt, :beam_weaver_graph_error]

  def invoke(node, input, runtime) do
    with {:ok, tool_calls, output_shape} <- Input.extract(input, node.messages_key) do
      request_state = Input.request_state(input, runtime)
      node = apply_tool_set(node, request_state)

      calls =
        for {call, index} <- Enum.with_index(tool_calls), do: call |> Input.normalize_call() |> Map.put(:index, index)

      # A call sent as a task of its own can pause the run, as a node can: its
      # process gets the node's scratchpad. Calls that share a task can't.
      scratchpad = if Input.sent_call?(input), do: Scratchpad.current()

      results =
        calls
        |> execution_groups(node)
        |> Enum.flat_map(&execute_group(&1, node, request_state, runtime, scratchpad))

      with :ok <- halt_on_signal(results) do
        results = Enum.flat_map(results, fn {call, result} -> List.wrap(normalize_task_result(node, call, result)) end)
        Enum.find(results, &match?({:error, %Error{}}, &1)) || Output.build(results, output_shape)
      end
    end
  end

  # A tool pauses the run by throwing a graph interrupt, as the `task` tool
  # does when its subagent pauses, or fails the whole step by throwing
  # `{:beam_weaver_graph_error, error}`. The step's other calls finish first;
  # then an error wins, else the first interrupt in call order pauses the node.
  defp halt_on_signal(results) do
    signals = for {_call, {:ok, {tag, _payload} = signal}} when tag in @signals <- results, do: signal

    case Enum.find(signals, &match?({:beam_weaver_graph_error, _error}, &1)) || List.first(signals) do
      nil -> :ok
      {:beam_weaver_graph_error, %Error{} = error} -> {:error, error}
      interrupt -> throw(interrupt)
    end
  end

  # Consecutive calls of concurrent tools run as one group; every other call
  # is a group of its own. Groups run one after another, each in call order.
  defp execution_groups(calls, node) do
    calls
    |> Enum.chunk_by(&tool_concurrent?(node, &1))
    |> Enum.flat_map(fn [call | _rest] = chunk ->
      if tool_concurrent?(node, call), do: [chunk], else: Enum.map(chunk, &[&1])
    end)
  end

  # Each call with its task's result, `{:ok, result}` or `{:exit, reason}`.
  defp execute_group(calls, node, request_state, runtime, scratchpad) do
    context = Tracing.capture_context()

    run = fn call ->
      Tracing.attach_context(context, fn ->
        with_scratchpad(scratchpad, fn -> execute_call(node, call, request_state, runtime) end)
      end)
    end

    opts = [ordered: true, timeout: node.timeout, on_timeout: :kill_task]

    results =
      case task_supervisor(runtime) do
        nil -> Task.async_stream(calls, run, opts)
        supervisor -> Task.Supervisor.async_stream_nolink(supervisor, calls, run, opts)
      end

    Enum.zip(calls, results)
  end

  defp with_scratchpad(nil, fun), do: fun.()
  defp with_scratchpad(scratchpad, fun), do: Scratchpad.with(scratchpad, fun)

  defp task_supervisor(%{task_supervisor: supervisor}) when not is_nil(supervisor),
    do: supervisor

  defp task_supervisor(%{execution: execution}) do
    case ToolRuntime.runtime_value(execution, :task_supervisor) do
      nil -> ToolRuntime.runtime_value(execution, "task_supervisor")
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

    node.wrap_tool_call
    |> Enum.filter(&Middleware.hook?(&1, :wrap_tool_call))
    |> Enum.reverse()
    |> Enum.reduce(&execute_tool_request(node, &1), fn middleware, inner ->
      fn request ->
        Middleware.call_wrapper(middleware, :wrap_tool_call, request, inner)
      end
    end)
    |> then(fn handler -> handler.(request) end)
    |> normalize_wrapped_tool_result()
    |> tap(&emit_tool_terminal(runtime, call, &1))
  rescue
    exception ->
      error =
        Error.new(:tool_middleware_exception, Exception.message(exception), %{
          tool: call.name,
          tool_call_id: call.id,
          exception: inspect(exception.__struct__)
        })

      node |> handle_tool_error(call, error) |> tap(&emit_tool_terminal(runtime, call, &1))
  catch
    :throw, {tag, _payload} = signal when tag in @signals ->
      signal

    kind, reason ->
      error =
        Error.new(:tool_middleware_exit, "tool middleware exited", %{
          tool: call.name,
          tool_call_id: call.id,
          kind: kind,
          reason: inspect(reason)
        })

      node |> handle_tool_error(call, error) |> tap(&emit_tool_terminal(runtime, call, &1))
  end

  defp execute_tool_request(node, %ToolCallRequest{} = request) do
    call = Input.normalize_call(request.tool_call)
    tool = request.tool || Map.get(node.tools, call.name)

    if is_nil(tool) do
      handle_tool_error(node, call, Error.new(:unknown_tool, "tool is not registered", %{tool: call.name}))
    else
      tool_runtime =
        ToolRuntime.new(
          tool: tool,
          tool_name: call.name,
          tool_call: call,
          tool_call_id: call.id,
          args: call.args,
          state: tool_state(node, request.state),
          runtime: request.runtime,
          tools: Map.values(node.tools)
        )

      with {:ok, args} <- inject_tool_args(tool, call, request.state, request.runtime, tool_runtime),
           {:ok, value} <-
             Tool.invoke(tool, args,
               tool_call_id: call.id,
               tool_runtime: %{tool_runtime | args: args},
               trace_input: call.args,
               trace_metadata: tool_call_trace_metadata(call)
             ),
           {:ok, output} <- Output.normalize(value, call) do
        Output.return_direct(output, tool)
      else
        {:error, %Error{} = error} -> handle_tool_error(node, call, error)
      end
    end
  end

  defp normalize_wrapped_tool_result({:ok, result}), do: result
  defp normalize_wrapped_tool_result(result), do: result

  defp tool_call_trace_metadata(call) do
    %{}
    |> put_present(:call_id, Map.get(call, :call_id))
    |> put_present(:id, Map.get(call, :id))
    |> put_present(:provider_id, Map.get(call, :provider_id))
    |> put_present(:tool_call_index, Map.get(call, :index))
  end

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

  defp tool_event_output(outputs) when is_list(outputs),
    do: Enum.map(outputs, &tool_event_output/1)

  defp tool_event_output(output), do: output

  defp normalize_task_result(node, call, {:ok, %Message{} = message}),
    do: truncate_tool_output(message, node, call)

  defp normalize_task_result(_node, _call, {:ok, %Command{} = command}), do: command

  defp normalize_task_result(node, call, {:ok, outputs}) when is_list(outputs),
    do: truncate_tool_output(outputs, node, call)

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
    error = Error.new(:tool_timeout, "tool timed out", %{tool: call.name, tool_call_id: call.id, timeout: node.timeout})
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

  # The content is written for the model; `error_message` keeps the tool's own
  # message, and `retryable` whether the error says retrying can help, for
  # middleware such as `ToolRetry` that handle the error again.
  defp tool_error_message(node, call, %Error{} = error) do
    Message.tool(format_error(node, error, call),
      tool_call_id: call.id,
      name: call.name,
      metadata: Map.merge(%{status: "error", error_type: error.type, error_message: error.message}, retryable(error))
    )
  end

  defp retryable(%Error{details: %{retryable: retryable}}) when is_boolean(retryable), do: %{retryable: retryable}
  defp retryable(%Error{}), do: %{}

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

  defp inject_tool_args(tool, call, state, runtime, tool_runtime) do
    tool
    |> Tool.injected()
    |> Enum.reduce_while({:ok, call.args}, fn {arg, source}, {:ok, acc} ->
      case injected_value(source, call, state, runtime, tool_runtime) do
        {:ok, value} ->
          {:cont, {:ok, Map.put(acc, arg, value)}}

        {:error, %Error{} = error} ->
          {:halt, {:error, error}}
      end
    end)
  end

  # The state a tool gets, without the node's private keys: an agent's tools
  # see what the run returns, not its bookkeeping, and can't hand the
  # bookkeeping on, as the `task` tool hands the state to a subagent.
  # `{:state, key}` still reads a private key by name.
  defp tool_state(%{private_keys: private_keys}, state) when is_map(state) and not is_struct(state),
    do: Map.reject(state, fn {key, _value} -> private_key?(private_keys, key) end)

  defp tool_state(_node, state), do: state

  defp private_key?(private_keys, key) when is_atom(key), do: MapSet.member?(private_keys, Atom.to_string(key))
  defp private_key?(private_keys, key) when is_binary(key), do: MapSet.member?(private_keys, key)
  defp private_key?(_private_keys, _key), do: false

  # An agent's tools node runs only the tools its model was offered on its
  # latest call: the run's tool set, or in a run that continued from a
  # checkpoint (after a review, a breakpoint or a crash), the registered tools
  # under the names the checkpoint keeps. Before the first model call, any
  # registered tool.
  defp apply_tool_set(node, input) do
    case {ToolSet.from_state(input), ToolSet.saved_names(input)} do
      {%ToolSet{} = tool_set, _names} -> %{node | tools: tool_set.tools}
      {nil, names} when is_list(names) -> %{node | tools: Map.take(node.tools, names)}
      {nil, nil} -> node
    end
  end

  defp injected_value(:state, _call, _state, _runtime, tool_runtime), do: {:ok, tool_runtime.state}

  defp injected_value({:state, field_or_path}, _call, state, _runtime, _tool_runtime),
    do: {:ok, get_state_field(state, field_or_path)}

  defp injected_value(source, _call, _state, runtime, _tool_runtime)
       when source in [:store, :context, :config, :checkpointer],
       do: {:ok, ToolRuntime.runtime_value(runtime, source)}

  defp injected_value(:runtime, _call, _state, runtime, _tool_runtime), do: {:ok, runtime}

  defp injected_value(:tool_runtime, _call, _state, _runtime, tool_runtime),
    do: {:ok, tool_runtime}

  defp injected_value(:tool_call_id, call, _state, _runtime, _tool_runtime),
    do: {:ok, call.id}

  defp injected_value(source, _call, _state, _runtime, _tool_runtime) do
    {:error,
     Error.new(:invalid_tool, "tool injected arg source is not supported", %{
       source: inspect(source)
     })}
  end

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
        with {_key, value} <- Enum.find(state, fn {key, _value} -> to_string(key) == field end), do: value

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

    ["Tool error: #{error.message}"]
    |> maybe_append("Args", sanitize_value(call.args, hidden))
    |> maybe_append("Details", sanitize_value(error.details, hidden))
    |> join_sentences()
  end

  @doc false
  def maybe_append(parts, _label, value) when value in [%{}, [], nil], do: parts
  def maybe_append(parts, label, value), do: parts ++ ["#{label}: #{inspect(value)}"]

  # Joins the parts with ". ", without doubling the period of a part that
  # already ends a sentence, such as an error message that ends with one.
  defp join_sentences([last]), do: last

  defp join_sentences([part | rest]) do
    separator = if String.ends_with?(part, [".", "!", "?"]), do: " ", else: ". "
    part <> separator <> join_sentences(rest)
  end

  defp hidden_arg_names(node, call) do
    injected =
      case Map.get(node.tools, call.name) do
        nil -> []
        tool -> tool |> Tool.injected() |> Map.keys()
      end

    MapSet.new(~w(state store runtime tool_runtime context config checkpointer tool_message) ++ injected, &to_string/1)
  end

  @doc false
  def sanitize_value(%{__struct__: _module} = value, _hidden), do: inspect(value)

  def sanitize_value(value, hidden) when is_map(value) do
    value
    |> Enum.reject(fn {key, _value} -> MapSet.member?(hidden, to_string(key)) end)
    |> Map.new(fn {key, value} -> {key, sanitize_value(value, hidden)} end)
  end

  def sanitize_value(values, hidden) when is_list(values) do
    values
    |> Enum.reject(fn value -> is_binary(value) and MapSet.member?(hidden, value) end)
    |> Enum.map(&sanitize_value(&1, hidden))
  end

  def sanitize_value(value, _hidden), do: value
end
