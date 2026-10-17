defmodule BeamWeaver.Agent.StructuredOutput.ResultHandler do
  @moduledoc false

  alias BeamWeaver.Agent.ModelResponse
  alias BeamWeaver.Agent.Nodes.Model.Response
  alias BeamWeaver.Agent.StructuredOutput.AutoStrategy
  alias BeamWeaver.Agent.StructuredOutput.ProviderStrategy
  alias BeamWeaver.Agent.StructuredOutput.ToolStrategy
  alias BeamWeaver.Agent.StructuredOutput.Validation
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message

  @spec handle_model_output(Message.t(), term(), [Message.t()]) ::
          {:ok, ModelResponse.t()} | {:error, Error.t()}
  def handle_model_output(%Message{} = message, nil, _history) do
    {:ok, %ModelResponse{messages: [message]}}
  end

  def handle_model_output(%Message{tool_calls: calls} = message, %ProviderStrategy{}, _history)
      when is_list(calls) and calls != [] do
    {:ok, %ModelResponse{messages: [message]}}
  end

  def handle_model_output(%Message{} = message, %ProviderStrategy{schema_spec: spec}, _history) do
    with {:ok, data} <- parsed_provider_data(message),
         {:ok, parsed} <- Validation.parse(spec, data) do
      {:ok, %ModelResponse{messages: [message], structured_response: parsed}}
    end
  end

  def handle_model_output(%Message{} = message, %ToolStrategy{} = strategy, history) do
    structured_calls =
      Enum.filter(message.tool_calls || [], fn call ->
        call_name(call) in Enum.map(strategy.schema_specs, & &1.name)
      end)

    case structured_calls do
      [] when message.tool_calls in [nil, []] ->
        missing_structured_call(strategy, message, history)

      [] ->
        {:ok, %ModelResponse{messages: [message]}}

      [_one, _two | _rest] ->
        names = structured_calls |> Enum.map(&call_name/1) |> Enum.reject(&is_nil/1)

        error =
          Error.new(
            :multiple_structured_outputs,
            "model returned multiple structured responses: #{Enum.join(names, ", ")}"
          )

        structured_error(strategy, error, message, structured_calls, history)

      [call] ->
        spec = Enum.find(strategy.schema_specs, &(&1.name == call_name(call)))

        with {:ok, args} <- call_args(call),
             {:ok, parsed} <- Validation.parse(spec, args) do
          message = annotate_structured_output_message(message, [spec.name])

          tool_message =
            Message.tool(
              strategy.tool_message_content || "Returning structured response: #{inspect(parsed)}",
              tool_call_id: Response.tool_call_id(call),
              name: spec.name,
              metadata: %{status: "success", structured_response: true}
            )

          {:ok,
           %ModelResponse{
             messages: [message, tool_message],
             structured_response: parsed
           }}
        else
          {:error, %Error{} = error} ->
            structured_error(strategy, error, message, [call], history)
        end
    end
  end

  def handle_model_output(%Message{} = message, %AutoStrategy{schema: schema, opts: opts}, history) do
    strategy =
      BeamWeaver.Agent.StructuredOutput.tool(
        schema,
        Keyword.take(opts || [], [:tool_message_content, :handle_errors, :max_retries])
      )

    handle_model_output(message, strategy, history)
  end

  # A reply that calls no tool at all is an answer without the structured
  # call: a model may ignore a forced tool choice, and some models (such as
  # Kimi with thinking on) can't be forced. It fails like an answer that
  # doesn't match the schema.
  defp missing_structured_call(%ToolStrategy{} = strategy, %Message{} = message, history) do
    names = Enum.map(strategy.schema_specs, & &1.name)

    error =
      Error.new(
        :missing_structured_output,
        "the answer must be a call to the #{Enum.join(names, " or ")} tool",
        %{tools: names}
      )

    structured_error(strategy, error, message, [], history)
  end

  # An answer that fails: with `handle_errors`, the model's reply stays in the
  # conversation followed by the error, as a tool message for each structured
  # call or as a user message when it made none, so the agent asks the model
  # again, until `max_retries` answers in a row have failed. Otherwise, or
  # after that, the error ends the run.
  defp structured_error(%ToolStrategy{} = strategy, %Error{} = error, message, calls, history) do
    failed = failed_attempts(history)

    cond do
      not handle_structured_error?(strategy.handle_errors, error.type) ->
        {:error, error}

      failed >= strategy.max_retries ->
        {:error, %{error | details: Map.put(error.details || %{}, :attempts, failed + 1)}}

      true ->
        content = structured_error_content(strategy.handle_errors, error)
        {:ok, %ModelResponse{messages: [message | error_messages(calls, content, error.type)]}}
    end
  end

  defp error_messages([], content, type),
    do: [Message.user(content, metadata: %{error_type: type, structured_output_error: true})]

  defp error_messages(calls, content, type) do
    Enum.map(calls, fn call ->
      Message.tool(content,
        tool_call_id: Response.tool_call_id(call),
        name: call_name(call),
        metadata: %{status: "error", error_type: type, structured_output_error: true}
      )
    end)
  end

  # The structured answers that failed since the person's last message,
  # counted by the assistant replies that got a structured-output error back.
  defp failed_attempts(history) do
    history
    |> List.wrap()
    |> Enum.reverse()
    |> Enum.take_while(&(not person_message?(&1)))
    |> Enum.reverse()
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.count(fn [reply, result] ->
      match?(%Message{role: :assistant}, reply) and structured_output_error?(result)
    end)
  end

  defp person_message?(%Message{role: :user} = message), do: not structured_output_error?(message)
  defp person_message?(_message), do: false

  @doc false
  # The error a failing structured answer got back: a tool message, or a
  # user message after a reply that called no tool.
  @spec structured_output_error?(term()) :: boolean()
  def structured_output_error?(%Message{role: role, metadata: %{structured_output_error: true}})
      when role in [:tool, :user],
      do: true

  def structured_output_error?(_message), do: false

  defp handle_structured_error?(true, _type), do: true
  defp handle_structured_error?(message, _type) when is_binary(message), do: true
  defp handle_structured_error?(formatter, _type) when is_function(formatter, 1), do: true
  defp handle_structured_error?(type, type) when is_atom(type), do: true
  defp handle_structured_error?(allowed, type) when is_list(allowed), do: type in allowed
  defp handle_structured_error?(_handle_errors, _type), do: false

  defp annotate_structured_output_message(%Message{} = message, names) do
    annotation = %{structured_output_strategy: :tool, structured_output_tool_names: names}

    %{
      message
      | metadata: Map.merge(map_or_empty(message.metadata), annotation),
        response_metadata: Map.merge(map_or_empty(message.response_metadata), annotation)
    }
  end

  defp map_or_empty(map) when is_map(map), do: map
  defp map_or_empty(_value), do: %{}

  defp structured_error_content(message, _error) when is_binary(message), do: message

  defp structured_error_content(formatter, error) when is_function(formatter, 1),
    do: formatter.(error)

  defp structured_error_content(_handle_errors, error),
    do: "Structured output error: #{error.message}#{error_detail(error.details)}. Fix it and answer again."

  defp error_detail(%{missing: [_ | _] = missing}), do: " (#{Enum.join(missing, ", ")})"
  defp error_detail(%{key: key, expected: type}) when is_binary(type), do: " (#{key}: expected #{type})"
  defp error_detail(_details), do: ""

  defp parsed_provider_data(%Message{metadata: metadata} = message) do
    if is_map(metadata) and Map.has_key?(metadata, :parsed) do
      {:ok, Map.fetch!(metadata, :parsed)}
    else
      decode_json(Message.text(message))
    end
  end

  defp decode_json(text) when is_binary(text) do
    case BeamWeaver.JSON.decode(text) do
      {:ok, data} when is_map(data) ->
        {:ok, data}

      {:ok, _other} ->
        {:error,
         Error.new(
           :structured_output_validation_error,
           "provider structured response must be an object"
         )}

      {:error, error} ->
        {:error,
         Error.new(
           :structured_output_parse_error,
           "provider structured response was not valid JSON",
           %{
             reason: Exception.message(error)
           }
         )}
    end
  end

  defp call_args(call) do
    args = Map.get(call, :args) || Map.get(call, :arguments) || %{}

    cond do
      is_map(args) ->
        {:ok, args}

      is_binary(args) ->
        case BeamWeaver.JSON.decode(args) do
          {:ok, decoded} when is_map(decoded) ->
            {:ok, decoded}

          _other ->
            {:error,
             Error.new(
               :structured_output_parse_error,
               "structured tool arguments were not valid JSON"
             )}
        end

      true ->
        {:error, Error.new(:structured_output_parse_error, "structured tool arguments must be an object")}
    end
  end

  defp call_name(call), do: Map.get(call, :name)
end
