defmodule BeamWeaver.XAI.Messages do
  @moduledoc """
  xAI message translation helpers.

  The xAI API is OpenAI-compatible for the chat surfaces BeamWeaver supports, so
  request translation delegates to the OpenAI translators and response
  translation adds the xAI-specific metadata and accounting details.
  """

  alias BeamWeaver.Core.Message
  alias BeamWeaver.OpenAI.ChatCompletions
  alias BeamWeaver.OpenAI.MessageParts
  alias BeamWeaver.OpenAI.Messages, as: OpenAIMessages
  alias BeamWeaver.XAI.Error

  @spec to_responses_input([Message.t()]) :: {:ok, [map()]} | {:error, Error.t()}
  def to_responses_input(messages),
    do: OpenAIMessages.to_responses_input(messages) |> convert_error()

  @spec normalize_input_items([map()] | nil) :: {:ok, [map()]} | {:error, Error.t()}
  def normalize_input_items(items),
    do: OpenAIMessages.normalize_input_items(items) |> convert_error()

  @spec last_after_previous_response([Message.t()]) :: {[Message.t()], String.t() | nil}
  def last_after_previous_response(messages),
    do: OpenAIMessages.last_after_previous_response(messages)

  @spec structured_output_format(String.t(), map(), keyword()) :: map()
  def structured_output_format(name, schema, opts \\ []) do
    name
    |> OpenAIMessages.structured_output_format(schema, opts)
    |> preserve_open_empty_object_maps()
  end

  @spec preserve_xai_open_object_maps(map()) :: map()
  def preserve_xai_open_object_maps(%{} = body) do
    body
    |> update_format_in(["text", "format"])
    |> update_format_in(["response_format"])
  end

  def preserve_xai_open_object_maps(body), do: body

  defp update_format_in(body, path) do
    case get_in(body, path) do
      %{} = format -> put_in(body, path, preserve_open_empty_object_maps(format))
      _other -> body
    end
  end

  defp preserve_open_empty_object_maps(%{"schema" => schema} = format) do
    Map.put(format, "schema", preserve_open_empty_object_maps(schema))
  end

  defp preserve_open_empty_object_maps(%{"json_schema" => %{"schema" => schema}} = format) do
    put_in(format, ["json_schema", "schema"], preserve_open_empty_object_maps(schema))
  end

  defp preserve_open_empty_object_maps(%{} = schema) do
    schema
    |> maybe_open_empty_object_map()
    |> update_schema_child("properties", fn properties ->
      Map.new(properties, fn {key, value} -> {key, preserve_open_empty_object_maps(value)} end)
    end)
    |> update_schema_child("items", &preserve_open_empty_object_maps/1)
    |> update_schema_child("anyOf", fn schemas -> Enum.map(schemas, &preserve_open_empty_object_maps/1) end)
    |> update_schema_child("oneOf", fn schemas -> Enum.map(schemas, &preserve_open_empty_object_maps/1) end)
    |> update_schema_child("allOf", fn schemas -> Enum.map(schemas, &preserve_open_empty_object_maps/1) end)
    |> update_schema_child("$defs", fn defs ->
      Map.new(defs, fn {key, value} -> {key, preserve_open_empty_object_maps(value)} end)
    end)
    |> update_schema_child("definitions", fn defs ->
      Map.new(defs, fn {key, value} -> {key, preserve_open_empty_object_maps(value)} end)
    end)
  end

  defp preserve_open_empty_object_maps(value), do: value

  defp maybe_open_empty_object_map(
         %{"type" => "object", "properties" => properties, "additionalProperties" => false} = schema
       )
       when properties == %{} or is_nil(properties) do
    required = Map.get(schema, "required", [])

    if required in [[], nil] do
      Map.drop(schema, ["properties", "required", "additionalProperties"])
    else
      schema
    end
  end

  defp maybe_open_empty_object_map(schema), do: schema

  defp update_schema_child(schema, key, fun) do
    case Map.fetch(schema, key) do
      {:ok, value} -> Map.put(schema, key, fun.(value))
      :error -> schema
    end
  end

  @spec to_chat_completions_messages([Message.t()]) :: {:ok, [map()]} | {:error, Error.t()}
  def to_chat_completions_messages(messages) do
    ChatCompletions.Messages.to_openai_messages(messages) |> convert_error()
  end

  @spec responses_to_message(map()) :: {:ok, Message.t()} | {:error, Error.t()}
  def responses_to_message(response) when is_map(response) do
    response
    |> OpenAIMessages.response_to_message()
    |> convert_error()
    |> put_provider_metadata(response)
  end

  @spec chat_completions_to_message(map()) :: {:ok, Message.t()} | {:error, Error.t()}
  def chat_completions_to_message(response) when is_map(response) do
    response
    |> ChatCompletions.Messages.response_to_message()
    |> convert_error()
    |> put_provider_metadata(response)
    |> put_chat_completion_metadata(response)
    |> adjust_reasoning_usage(response)
  end

  defp convert_error({:error, %BeamWeaver.OpenAI.Error{} = error}) do
    {:error, Error.new(error.type, error.message, error.details)}
  end

  defp convert_error(other), do: other

  defp put_provider_metadata({:ok, %Message{} = message}, _response) do
    metadata = put_xai_provider(message.metadata)
    response_metadata = put_xai_provider(message.response_metadata)

    {:ok, %{message | metadata: metadata, response_metadata: response_metadata}}
  end

  defp put_provider_metadata(other, _response), do: other

  defp put_chat_completion_metadata({:ok, %Message{} = message}, response) do
    extras =
      %{}
      |> put_optional(:reasoning_content, reasoning_content(response))
      |> put_optional(:citations, citations(response))

    metadata =
      message.metadata
      |> Map.merge(extras)
      |> MessageParts.reject_nil_values()

    response_metadata =
      message.response_metadata
      |> Map.merge(extras)
      |> MessageParts.reject_nil_values()

    {:ok, %{message | metadata: metadata, response_metadata: response_metadata}}
  end

  defp put_chat_completion_metadata(other, _response), do: other

  defp adjust_reasoning_usage({:ok, %Message{usage_metadata: nil} = message}, _response),
    do: {:ok, message}

  defp adjust_reasoning_usage({:ok, %Message{} = message}, response) do
    reasoning_tokens = reasoning_tokens(response)

    usage =
      if reasoning_tokens > 0 do
        usage = message.usage_metadata
        base_output = Map.get(usage, :output_tokens, 0)
        input = Map.get(usage, :input_tokens, 0)
        raw_total = Map.get(usage, :total_tokens, 0)
        adjusted_output = base_output + reasoning_tokens

        adjusted_total =
          if raw_total == input + base_output do
            raw_total + reasoning_tokens
          else
            raw_total
          end

        %{usage | output_tokens: adjusted_output, total_tokens: adjusted_total}
      else
        message.usage_metadata
      end

    {:ok, %{message | usage_metadata: usage}}
  end

  defp adjust_reasoning_usage(other, _response), do: other

  defp put_xai_provider(metadata) do
    metadata
    |> Map.put(:model_provider, "xai")
    |> Map.put(:provider, :xai)
  end

  defp reasoning_content(response) do
    response
    |> first_choice_message()
    |> case do
      %{"reasoning_content" => reasoning} when is_binary(reasoning) -> reasoning
      %{"reasoning" => reasoning} when is_binary(reasoning) -> reasoning
      _message -> nil
    end
  end

  defp citations(response) do
    cond do
      is_list(response["citations"]) ->
        response["citations"]

      is_list(get_in(response, ["choices", Access.at(0), "citations"])) ->
        get_in(response, ["choices", Access.at(0), "citations"])

      is_list(get_in(response, ["choices", Access.at(0), "message", "citations"])) ->
        get_in(response, ["choices", Access.at(0), "message", "citations"])

      true ->
        nil
    end
  end

  defp reasoning_tokens(response) do
    response
    |> get_in(["usage", "completion_tokens_details", "reasoning_tokens"])
    |> Kernel.||(get_in(response, ["usage", "output_tokens_details", "reasoning_tokens"]))
    |> case do
      value when is_integer(value) and value > 0 -> value
      _value -> 0
    end
  end

  defp first_choice_message(%{"choices" => [%{"message" => message} | _rest]})
       when is_map(message),
       do: message

  defp first_choice_message(_response), do: nil

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, _key, []), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)
end
