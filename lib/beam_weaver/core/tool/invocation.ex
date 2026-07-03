defmodule BeamWeaver.Core.Tool.Invocation do
  @moduledoc false

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Tool.Output
  alias BeamWeaver.Core.Tool.Schema

  @type api :: %{
          args: (term() -> map()),
          do_invoke: (term(), map(), keyword() -> {:ok, term()} | {:error, Error.t()}),
          handle_tool_error: (term() -> term()),
          handle_validation_error: (term() -> term()),
          injected: (term() -> map()),
          input_schema: (term() -> map()),
          name: (term() -> String.t()),
          parse_args: (term(), map() -> :ok | {:ok, map()} | {:error, term()}),
          response_format: (term() -> term())
        }

  @spec invoke(term(), term(), keyword(), api()) :: {:ok, term()} | {:error, Error.t()}
  def invoke(tool, input, opts, api) when is_map(input) do
    error_call = invocation_error_context(tool, input, api)

    case normalize_invocation(tool, input, api) do
      {:ok, call} ->
        invoke_normalized(tool, call, opts, api)

      {:error, %Error{} = error} ->
        handle_invocation_error(tool, error, error_call, api)
    end
  end

  def invoke(tool, input, opts, api) do
    if single_input?(tool, api) do
      [key] = tool |> api.args.() |> Map.keys()
      invoke(tool, %{key => input}, opts, api)
    else
      handle_invocation_error(
        tool,
        Error.new(:invalid_input, "tool input must be a map"),
        %{input: input, tool_call_id: nil, tool_call_name: nil, wrap_output?: false},
        api
      )
    end
  end

  defp single_input?(tool, api), do: map_size(api.args.(tool)) == 1

  defp normalize_invocation(tool, input, api) do
    if tool_call_input?(input) do
      normalize_tool_call_invocation(tool, input, api)
    else
      {:ok, %{input: input, tool_call_id: nil, tool_call_name: nil, wrap_output?: false}}
    end
  end

  defp tool_call_input?(input) do
    BeamWeaver.MapAccess.get(input, :type) in [:tool_call, "tool_call"]
  end

  defp normalize_tool_call_invocation(tool, input, api) do
    args = BeamWeaver.MapAccess.get(input, :args)
    call_name = BeamWeaver.MapAccess.get(input, :name)
    call_id = BeamWeaver.MapAccess.get(input, :id)
    tool_name = api.name.(tool)

    cond do
      not is_map(args) ->
        {:error, Error.new(:invalid_input, "tool_call input must include map args")}

      is_binary(call_name) and call_name != tool_name ->
        {:error,
         Error.new(:invalid_input, "tool_call name does not match tool", %{
           expected: tool_name,
           actual: call_name
         })}

      true ->
        {:ok,
         %{
           input: args,
           tool_call_id: call_id,
           tool_call_name: call_name || tool_name,
           wrap_output?: true
         }}
    end
  end

  defp invocation_error_context(tool, input, api) do
    if tool_call_input?(input) do
      %{
        input: BeamWeaver.MapAccess.get(input, :args),
        tool_call_id: BeamWeaver.MapAccess.get(input, :id),
        tool_call_name: BeamWeaver.MapAccess.get(input, :name) || api.name.(tool),
        wrap_output?: true
      }
    else
      %{input: input, tool_call_id: nil, tool_call_name: nil, wrap_output?: false}
    end
  end

  defp invoke_normalized(tool, call, opts, api) do
    schema = api.input_schema.(tool)

    with {:ok, parsed_input} <- parse_input(tool, call.input, api),
         defaulted_input <- Schema.apply_defaults(parsed_input, schema),
         :ok <- Schema.validate(schema, defaulted_input),
         input <- inject_call_id(defaulted_input, tool, call, api),
         {:ok, result} <- api.do_invoke.(tool, input, opts) do
      {:ok, format_invocation_result(result, tool, call, api)}
    else
      {:error, %Error{} = error} -> handle_invocation_error(tool, error, call, api)
    end
  end

  defp parse_input(tool, input, api) do
    case api.parse_args.(tool, input) do
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

  defp handle_invocation_error(tool, %Error{type: :invalid_input} = error, call, api) do
    handle_error_policy(api.handle_validation_error.(tool), error, tool, call, api)
  end

  defp handle_invocation_error(tool, %Error{type: type} = error, call, api)
       when type in [:tool_exception, :tool_error] do
    handle_error_policy(api.handle_tool_error.(tool), error, tool, call, api)
  end

  defp handle_invocation_error(_tool, %Error{} = error, _call, _api), do: {:error, error}

  defp handle_error_policy(policy, error, tool, call, api) do
    case format_error_content(policy, error) do
      {:ok, content} -> {:ok, format_error_result(content, tool, call, api)}
      :error -> {:error, error}
    end
  end

  defp format_error_content(nil, _error), do: :error
  defp format_error_content(false, _error), do: :error
  defp format_error_content(true, %Error{} = error), do: {:ok, error.message}
  defp format_error_content(message, _error) when is_binary(message), do: {:ok, message}

  defp format_error_content(fun, %Error{} = error) when is_function(fun, 1) do
    {:ok, fun.(error)}
  rescue
    exception ->
      {:ok, "tool error handler failed: #{Exception.message(exception)}"}
  end

  defp format_error_content(_policy, _error), do: :error

  defp format_error_result(content, tool, %{wrap_output?: true} = call, api) do
    Output.format(content,
      tool_call_id: call.tool_call_id,
      name: call.tool_call_name || api.name.(tool),
      status: :error
    )
  end

  defp format_error_result(content, _tool, _call, _api), do: content

  defp inject_call_id(input, _tool, %{tool_call_id: nil}, _api), do: input

  defp inject_call_id(input, tool, %{tool_call_id: call_id}, api) do
    tool
    |> api.injected.()
    |> Enum.filter(fn {_key, source} -> source == :tool_call_id end)
    |> Enum.reduce(input, fn {key, _source}, acc -> Map.put(acc, key, call_id) end)
  end

  defp format_invocation_result(result, tool, %{wrap_output?: true} = call, api) do
    Output.format(result,
      tool_call_id: call.tool_call_id,
      name: call.tool_call_name || api.name.(tool),
      status: :success
    )
  end

  defp format_invocation_result(result, tool, %{wrap_output?: false}, api) do
    if api.response_format.(tool) == :content_and_artifact do
      {content, _artifact, _status} = Output.split_result(result, nil, :success)
      content
    else
      result
    end
  end
end
