defmodule BeamWeaver.Core.Tool.Invocation do
  @moduledoc false

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Core.Tool.Output
  alias BeamWeaver.Core.Tool.Passthrough
  alias BeamWeaver.Core.Tool.Schema
  alias BeamWeaver.Core.ToolResult

  @spec invoke(term(), term(), keyword()) :: {:ok, term()} | {:error, Error.t()}
  def invoke(tool, input, opts) when is_map(input) do
    call = invocation_call(tool, input)

    case validate_tool_call(tool, call) do
      :ok -> invoke_normalized(tool, call, opts)
      {:error, %Error{} = error} -> handle_invocation_error(tool, error, call)
    end
  end

  def invoke(tool, input, opts) do
    if Tool.single_input?(tool) do
      [key] = tool |> Tool.args() |> Map.keys()
      invoke(tool, %{key => input}, opts)
    else
      handle_invocation_error(tool, Error.new(:invalid_input, "tool input must be a map"), invocation_call(tool, input))
    end
  end

  def tool_call_input?(input) do
    BeamWeaver.MapAccess.get(input, :type) in [:tool_call, "tool_call"]
  end

  defp invocation_call(tool, input) do
    if tool_call_input?(input) do
      %{
        input: BeamWeaver.MapAccess.get(input, :args),
        tool_call_id: BeamWeaver.MapAccess.get(input, :id),
        tool_call_name: BeamWeaver.MapAccess.get(input, :name) || Tool.name(tool),
        wrap_output?: true
      }
    else
      %{input: input, tool_call_id: nil, tool_call_name: nil, wrap_output?: false}
    end
  end

  defp validate_tool_call(_tool, %{wrap_output?: false}), do: :ok

  defp validate_tool_call(_tool, %{input: args}) when not is_map(args),
    do: {:error, Error.new(:invalid_input, "tool_call input must include map args")}

  defp validate_tool_call(tool, %{tool_call_name: call_name}) do
    tool_name = Tool.name(tool)

    if is_binary(call_name) and call_name != tool_name do
      {:error,
       Error.new(:invalid_input, "tool_call name does not match tool", %{expected: tool_name, actual: call_name})}
    else
      :ok
    end
  end

  defp invoke_normalized(tool, call, opts) do
    schema = Tool.input_schema(tool)

    with {:ok, parsed_input} <- parse_input(tool, call.input),
         defaulted_input <- Schema.apply_defaults(parsed_input, schema),
         validation_input <- without_injected(defaulted_input, Tool.injected(tool)),
         :ok <- Schema.validate(schema, validation_input),
         input <- inject_call_id(defaulted_input, tool, call),
         {:ok, result} <- do_invoke(tool, input, opts) do
      {:ok, format_invocation_result(result, tool, call)}
    else
      {:error, %Error{} = error} -> handle_invocation_error(tool, error, call)
    end
  end

  defp do_invoke(%Tool{handler: handler}, input, opts) do
    normalize_result(handler.(input, opts))
  rescue
    exception -> {:error, Error.new(:tool_exception, Exception.message(exception))}
  end

  defp do_invoke(%module{} = tool, input, opts), do: normalize_result(module.invoke(tool, input, opts))
  defp do_invoke(module, input, opts), do: normalize_result(module.invoke(module, input, opts))

  defp normalize_result({:ok, _value} = result), do: result
  defp normalize_result({:error, %Error{}} = result), do: result

  defp normalize_result({:error, reason}) when is_binary(reason), do: {:error, Error.new(:tool_error, reason)}

  defp normalize_result({:error, reason}),
    do: {:error, Error.new(:tool_error, "tool returned an error", %{reason: inspect(reason)})}

  defp normalize_result(value), do: {:ok, value}

  def without_injected(input, injected) when map_size(injected) == 0, do: input

  def without_injected(input, injected) do
    names = injected |> Map.keys() |> MapSet.new(&to_string/1)
    Map.reject(input, fn {key, _value} -> MapSet.member?(names, to_string(key)) end)
  end

  defp parse_input(tool, input) do
    case Tool.parse_args(tool, input) do
      :ok ->
        {:ok, input}

      {:ok, parsed} when is_map(parsed) ->
        {:ok, parsed}

      {:ok, parsed} ->
        {:error,
         Error.new(:invalid_input, "tool parse_args returned a non-map", %{
           parsed: inspect(parsed)
         })}

      {:error, reason} ->
        {:error,
         Error.new(:invalid_input, "tool parse_args rejected input", %{
           reason: format_reason(reason)
         })}

      other ->
        {:error,
         Error.new(:invalid_input, "tool parse_args returned an invalid result", %{
           result: inspect(other)
         })}
    end
  rescue
    exception ->
      {:error,
       Error.new(:invalid_input, "tool parse_args raised an exception", %{
         exception: inspect(exception.__struct__),
         reason: Exception.message(exception)
       })}
  catch
    kind, reason ->
      {:error,
       Error.new(:invalid_input, "tool parse_args exited", %{
         kind: kind,
         reason: inspect(reason)
       })}
  end

  defp format_reason(%Error{} = error) do
    %{type: error.type, message: error.message, details: error.details}
  end

  defp format_reason(reason), do: inspect(reason)

  defp handle_invocation_error(tool, %Error{type: :invalid_input} = error, call) do
    handle_error_policy(Tool.handle_validation_error(tool), error, tool, call)
  end

  defp handle_invocation_error(tool, %Error{type: type} = error, call)
       when type in [:tool_exception, :tool_error] do
    handle_error_policy(Tool.handle_tool_error(tool), error, tool, call)
  end

  defp handle_invocation_error(_tool, %Error{} = error, _call), do: {:error, error}

  defp handle_error_policy(policy, error, tool, call) do
    case format_error_content(policy, error) do
      {:ok, content} -> {:ok, format_error_result(content, tool, call)}
      :error -> {:error, error}
    end
  end

  defp format_error_content(true, %Error{} = error), do: {:ok, error.message}
  defp format_error_content(message, _error) when is_binary(message), do: {:ok, message}

  defp format_error_content(fun, %Error{} = error) when is_function(fun, 1) do
    {:ok, fun.(error)}
  rescue
    exception ->
      {:ok, "tool error handler failed: #{Exception.message(exception)}"}
  end

  defp format_error_content(_policy, _error), do: :error

  defp format_error_result(content, _tool, %{wrap_output?: true} = call), do: wrap_output(content, call, :error)
  defp format_error_result(content, _tool, _call), do: content

  defp wrap_output(content, call, status),
    do: Output.format(content, tool_call_id: call.tool_call_id, name: call.tool_call_name, status: status)

  defp inject_call_id(input, _tool, %{tool_call_id: nil}), do: input

  defp inject_call_id(input, tool, %{tool_call_id: call_id}),
    do: for({key, :tool_call_id} <- Tool.injected(tool), into: input, do: {key, call_id})

  defp format_invocation_result(result, _tool, %{wrap_output?: true} = call), do: wrap_output(result, call, :success)

  # A `:content_and_artifact` tool returns `{content, artifact}`; both travel on
  # as a `ToolResult`, which an agent's tool node turns into a tool message
  # with the artifact in `metadata.artifact`. A struct, such as a message or a
  # graph command, or a list of structs passes through as it is, as from any
  # tool, for the tool node to read.
  defp format_invocation_result(result, tool, %{wrap_output?: false}) do
    if Tool.response_format(tool) in [:content_and_artifact, "content_and_artifact"] and
         not passed_through?(result) do
      content_and_artifact(result)
    else
      result
    end
  end

  defp content_and_artifact({:content_and_artifact, content, artifact}),
    do: ToolResult.success(content, artifact: artifact)

  defp content_and_artifact(result) do
    {content, artifact, status} = Output.split_result(result, nil, :success)
    ToolResult.success(content, artifact: artifact, status: status)
  end

  # A message, a command for the runtime, or a list of them is the tool's
  # output as it is; anything else is its content.
  defp passed_through?([_ | _] = outputs), do: Enum.all?(outputs, &single_output?/1)
  defp passed_through?(result), do: single_output?(result)

  defp single_output?(%Message{}), do: true
  defp single_output?(result), do: Passthrough.passthrough?(result)
end
