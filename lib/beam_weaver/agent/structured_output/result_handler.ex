defmodule BeamWeaver.Agent.StructuredOutput.ResultHandler do
  @moduledoc false

  alias BeamWeaver.Agent.ModelResponse
  alias BeamWeaver.Agent.StructuredOutput.AutoStrategy
  alias BeamWeaver.Agent.StructuredOutput.ProviderStrategy
  alias BeamWeaver.Agent.StructuredOutput.Schema
  alias BeamWeaver.Agent.StructuredOutput.ToolStrategy
  alias BeamWeaver.Agent.StructuredOutput.Validation
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message

  @spec handle_model_output(Message.t(), term()) :: {:ok, ModelResponse.t()} | {:error, Error.t()}
  def handle_model_output(%Message{} = message, nil) do
    {:ok, %ModelResponse{messages: [message]}}
  end

  def handle_model_output(%Message{} = message, %ProviderStrategy{schema_spec: spec}) do
    with {:ok, data} <- parsed_provider_data(message),
         {:ok, parsed} <- Validation.parse(spec, data) do
      {:ok, %ModelResponse{messages: [message], structured_response: parsed}}
    else
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  def handle_model_output(%Message{} = message, %ToolStrategy{} = strategy) do
    structured_calls =
      Enum.filter(message.tool_calls || [], fn call ->
        call_name(call) in Enum.map(strategy.schema_specs, & &1.name)
      end)

    case structured_calls do
      [] ->
        {:ok, %ModelResponse{messages: [message]}}

      [_one, _two | _rest] ->
        names = structured_calls |> Enum.map(&call_name/1) |> Enum.reject(&is_nil/1)

        structured_error(
          strategy,
          :multiple_structured_outputs,
          "model returned multiple structured responses: #{Enum.join(names, ", ")}"
        )

      [call] ->
        spec = Enum.find(strategy.schema_specs, &(&1.name == call_name(call)))

        with {:ok, args} <- call_args(call),
             {:ok, parsed} <- Validation.parse(spec, args) do
          tool_message =
            Message.tool(
              strategy.tool_message_content || "Returning structured response: #{inspect(parsed)}",
              tool_call_id: call_id(call),
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
            structured_error(strategy, error.type, error.message, call)
        end
    end
  end

  def handle_model_output(%Message{} = message, %AutoStrategy{schema: schema}) do
    strategy = %ToolStrategy{schema: schema, schema_specs: Schema.schema_specs(schema)}
    handle_model_output(message, strategy)
  end

  defp structured_error(strategy, type, message, call \\ nil)

  defp structured_error(%ToolStrategy{handle_errors: false}, type, message, _call) do
    {:error, Error.new(type, message)}
  end

  defp structured_error(%ToolStrategy{} = strategy, type, message, call) do
    if handle_structured_error?(strategy.handle_errors, type) do
      error = Error.new(type, message)
      content = structured_error_content(strategy.handle_errors, error)

      tool_message =
        Message.tool(content,
          tool_call_id: (call && call_id(call)) || "structured_output_error",
          name: (call && call_name(call)) || "structured_output",
          metadata: %{status: "error", error_type: type}
        )

      {:ok, %ModelResponse{messages: [tool_message]}}
    else
      {:error, Error.new(type, message)}
    end
  end

  defp handle_structured_error?(true, _type), do: true
  defp handle_structured_error?(false, _type), do: false
  defp handle_structured_error?(message, _type) when is_binary(message), do: true
  defp handle_structured_error?(formatter, _type) when is_function(formatter, 1), do: true
  defp handle_structured_error?(type, type) when is_atom(type), do: true
  defp handle_structured_error?(allowed, type) when is_list(allowed), do: type in allowed
  defp handle_structured_error?(_handle_errors, _type), do: false

  defp structured_error_content(message, _error) when is_binary(message), do: message

  defp structured_error_content(formatter, error) when is_function(formatter, 1),
    do: formatter.(error)

  defp structured_error_content(_handle_errors, error),
    do: "Structured output error: #{error.message}"

  defp parsed_provider_data(%Message{metadata: metadata} = message) do
    if is_map(metadata) and Map.has_key?(metadata, :parsed) do
      {:ok, Map.fetch!(metadata, :parsed)}
    else
      decode_json(Message.text(message))
    end
  rescue
    _exception -> decode_json("")
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

  defp call_id(call),
    do:
      Map.get(call, :id) ||
        Map.get(call, :tool_call_id)
end
