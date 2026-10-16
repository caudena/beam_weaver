defmodule BeamWeaver.XAI.Messages do
  @moduledoc false

  import BeamWeaver.MapShape, only: [put_optional: 3]

  alias BeamWeaver.Core.Message
  alias BeamWeaver.OpenAI.ChatCompletions
  alias BeamWeaver.OpenAI.MessageParts
  alias BeamWeaver.OpenAI.Messages, as: OpenAIMessages
  alias BeamWeaver.Core.Error

  @spec to_responses_input([Message.t()]) :: {:ok, [map()]} | {:error, Error.t()}
  def to_responses_input(messages),
    do: OpenAIMessages.to_responses_input(messages)

  @spec normalize_input_items([map()] | nil) :: {:ok, [map()]} | {:error, Error.t()}
  def normalize_input_items(items),
    do: OpenAIMessages.normalize_input_items(items)

  # xAI's response ids are UUIDs, such as "94fa5e70-e18c-9f53-9368-d77dabd2b8a7".
  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

  # The id of a reply xAI's Responses API stored, the only kind
  # `previous_response_id` continues from. A reply from another provider, from
  # xAI's Chat Completions API, or made with `store: false` (xAI answers 404
  # for its id) gets nil.
  @spec response_id(Message.t()) :: String.t() | nil
  def response_id(%Message{role: :assistant, response_metadata: %{model_provider: "xai", api: :responses} = metadata}) do
    id = metadata[:id]
    if is_binary(id) and Regex.match?(@uuid, id) and stored?(metadata), do: id
  end

  def response_id(_message), do: nil

  defp stored?(%{raw_provider_response: %{"store" => false}}), do: false
  defp stored?(_metadata), do: true

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
    ChatCompletions.Messages.to_openai_messages(messages)
  end

  @spec responses_to_message(map()) :: {:ok, Message.t()} | {:error, Error.t()}
  def responses_to_message(response) when is_map(response) do
    response
    |> OpenAIMessages.response_to_message()
    |> put_provider_metadata(:responses)
  end

  # A Responses reply decoded by the OpenAI decoder, as a stream's final
  # message is, becomes the same message `responses_to_message/1` returns.
  @spec put_responses_metadata(Message.t()) :: Message.t()
  def put_responses_metadata(%Message{} = message) do
    {:ok, message} = put_provider_metadata({:ok, message}, :responses)
    message
  end

  @spec chat_completions_to_message(map()) :: {:ok, Message.t()} | {:error, Error.t()}
  def chat_completions_to_message(response) when is_map(response) do
    response
    |> ChatCompletions.Messages.response_to_message()
    |> put_provider_metadata(:chat_completions)
    |> put_chat_completion_metadata(response)
    |> adjust_reasoning_usage(response)
  end

  defp put_provider_metadata({:ok, %Message{} = message}, api) do
    metadata = put_xai_provider(message.metadata, api)
    response_metadata = put_xai_provider(message.response_metadata, api)

    {:ok, %{message | metadata: metadata, response_metadata: response_metadata}}
  end

  defp put_provider_metadata(other, _api), do: other

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

  defp put_xai_provider(metadata, api) do
    metadata
    |> Map.put(:model_provider, "xai")
    |> Map.put(:provider, :xai)
    |> Map.put(:api, api)
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
end
