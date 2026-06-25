defmodule BeamWeaver.Agent.Middleware.Hooks do
  @moduledoc false

  alias BeamWeaver.Agent.Middleware.Capabilities
  alias BeamWeaver.Agent.Middleware.ModelCallLimit
  alias BeamWeaver.Agent.Middleware.ToolCallLimit
  alias BeamWeaver.Agent.ModelRequest
  alias BeamWeaver.Agent.ModelResponse
  alias BeamWeaver.Agent.ToolCallRequest
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Graph.Command
  alias BeamWeaver.Tracing

  @type middleware :: module() | struct()
  @type hook_result ::
          nil
          | map()
          | {:ok, map()}
          | {:error, term()}
          | {:jump, :model | :tools | :end, map()}
          | BeamWeaver.Graph.Command.t()

  @hooks [
    :before_agent,
    :before_model,
    :after_model,
    :after_agent,
    :wrap_model_call,
    :wrap_tool_call
  ]

  @spec hook?(middleware(), atom()) :: boolean()
  def hook?(middleware, hook) when hook in @hooks do
    module = middleware_module(middleware)
    Code.ensure_loaded?(module)
    function_exported?(module, hook, 2) or function_exported?(module, hook, 3)
  end

  def hook?(_middleware, _hook), do: false

  @spec call_hook(middleware(), atom(), map(), BeamWeaver.Graph.Runtime.t()) :: hook_result()
  def call_hook(middleware, hook, state, runtime)
      when hook in [:before_agent, :before_model, :after_model, :after_agent] do
    module = middleware_module(middleware)
    Code.ensure_loaded?(module)

    trace_middleware(middleware, hook, hook_inputs(state), fn ->
      cond do
        function_exported?(module, hook, 3) -> apply(module, hook, [middleware, state, runtime])
        function_exported?(module, hook, 2) -> apply(module, hook, [state, runtime])
      end
    end)
  end

  @spec call_wrapper(middleware(), :wrap_model_call | :wrap_tool_call, term(), function()) ::
          term()
  def call_wrapper(middleware, hook, request, handler)
      when hook in [:wrap_model_call, :wrap_tool_call] do
    module = middleware_module(middleware)
    Code.ensure_loaded?(module)

    trace_middleware(middleware, hook, wrapper_inputs(request), fn ->
      cond do
        function_exported?(module, hook, 3) -> apply(module, hook, [middleware, request, handler])
        function_exported?(module, hook, 2) -> apply(module, hook, [request, handler])
      end
    end)
  end

  defp middleware_module(module) when is_atom(module), do: module
  defp middleware_module(%{__struct__: module}), do: module

  defp trace_middleware(middleware, hook, inputs, fun) when is_function(fun, 0) do
    if trace_middleware?() do
      {:ok, run} =
        Tracing.start_run(trace_name(middleware, hook),
          kind: :chain,
          inputs: inputs,
          tags: [:middleware, hook],
          metadata: trace_metadata(middleware, hook),
          context_metadata: %{}
        )

      try do
        result = fun.()
        finish_middleware_run(run, result)
        result
      rescue
        exception ->
          Tracing.fail_run(run, exception)
          reraise exception, __STACKTRACE__
      catch
        kind, reason ->
          Tracing.fail_run(run, %{kind: kind, reason: reason})
          :erlang.raise(kind, reason, __STACKTRACE__)
      end
    else
      fun.()
    end
  end

  defp trace_middleware? do
    not is_nil(Tracing.capture_context()) or Tracing.exporter_configured?()
  end

  defp finish_middleware_run(run, {:error, error}) do
    Tracing.fail_run(run, error)
  end

  defp finish_middleware_run(run, result) do
    Tracing.finish_run(run, outputs: trace_outputs(result))
  end

  defp trace_name(middleware, hook) do
    case middleware_trace_identity(middleware) do
      nil -> "#{middleware_display_name(middleware)}.#{hook}"
      identity -> "#{middleware_display_name(middleware)}[#{identity}].#{hook}"
    end
  end

  defp middleware_trace_identity(%ToolCallLimit{} = middleware), do: middleware_name(middleware)
  defp middleware_trace_identity(%ModelCallLimit{} = middleware), do: middleware_name(middleware)
  defp middleware_trace_identity(_middleware), do: nil

  defp middleware_display_name(middleware) do
    case middleware_module(middleware) |> Module.split() |> List.last() do
      "ToolCallNormalization" -> "PatchToolCallsMiddleware"
      "TodoList" -> "TodoListMiddleware"
      "Filesystem" -> "FilesystemMiddleware"
      "Subagents" -> "SubAgentMiddleware"
      "AsyncSubagents" -> "AsyncSubAgentMiddleware"
      "CompactConversation" -> "SummarizationMiddleware"
      "PromptCaching" -> "AnthropicPromptCachingMiddleware"
      name when is_binary(name) -> ensure_middleware_suffix(name)
    end
  end

  defp ensure_middleware_suffix(name) do
    if String.ends_with?(name, "Middleware"), do: name, else: "#{name}Middleware"
  end

  defp trace_metadata(middleware, hook) do
    module = middleware_module(middleware)

    %{
      middleware: middleware_name(middleware),
      middleware_module: inspect(module),
      middleware_hook: hook
    }
  end

  defp middleware_name(middleware) do
    middleware
    |> Capabilities.name()
    |> to_string()
  rescue
    _exception -> inspect(middleware_module(middleware))
  end

  defp hook_inputs(state) when is_map(state) do
    %{
      state_keys: state_keys(state),
      messages_count: state |> state_messages() |> length()
    }
  end

  defp hook_inputs(_state), do: %{}

  defp wrapper_inputs(%ModelRequest{} = request) do
    %{
      type: :model_request,
      messages_count: length(request.messages || []),
      has_system_message: not is_nil(request.system_message),
      tools: Enum.map(request.tools || [], &tool_name/1),
      state_keys: state_keys(request.state || %{}),
      response_format: not is_nil(request.response_format)
    }
  end

  defp wrapper_inputs(%ToolCallRequest{} = request) do
    call = request.tool_call || %{}

    %{
      type: :tool_call_request,
      tool_name: Map.get(call, :name) || Map.get(call, "name"),
      tool_call_id: Map.get(call, :id) || Map.get(call, "id"),
      args: Map.get(call, :args) || Map.get(call, "args") || %{}
    }
  end

  defp wrapper_inputs(_request), do: %{}

  defp trace_outputs(result), do: %{output: trace_output(result)}

  defp trace_output({:ok, value}), do: %{status: "ok", value: trace_output(value)}

  defp trace_output(%ModelResponse{} = response) do
    %{
      type: "model_response",
      messages_count: length(response.messages || []),
      structured_response: not is_nil(response.structured_response),
      commands_count: length(response.commands || [])
    }
  end

  defp trace_output(%Message{} = message) do
    %{
      type: "message",
      role: message.role,
      name: message.name,
      tool_call_id: message.tool_call_id,
      tool_calls_count: length(message.tool_calls || []),
      content_length: message |> Message.text() |> byte_size()
    }
  end

  defp trace_output(%Command{update: update}) when is_map(update) do
    %{type: "command", update_keys: state_keys(update)}
  end

  defp trace_output(value) when is_map(value), do: %{type: "map", keys: state_keys(value)}
  defp trace_output(value) when is_list(value), do: %{type: "list", count: length(value)}
  defp trace_output(nil), do: nil
  defp trace_output(value) when is_binary(value), do: String.slice(value, 0, 500)
  defp trace_output(value), do: inspect(value)

  defp state_messages(state) when is_map(state) do
    Map.get(state, :messages) || Map.get(state, "messages") || []
  end

  defp state_keys(state) when is_map(state) do
    state
    |> Map.keys()
    |> Enum.map(&safe_key/1)
    |> Enum.sort()
  end

  defp safe_key(key) when is_atom(key) or is_binary(key), do: to_string(key)
  defp safe_key(key), do: inspect(key)

  defp tool_name(tool) do
    BeamWeaver.Core.Tool.name(tool)
  rescue
    _exception -> inspect(tool)
  end
end
