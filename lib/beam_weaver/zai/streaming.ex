defmodule BeamWeaver.ZAI.Streaming do
  @moduledoc false

  alias BeamWeaver.Core.Messages
  alias BeamWeaver.Core.Messages.MessageChunk
  alias BeamWeaver.OpenAI.MessageParts
  alias BeamWeaver.OpenAI.Streaming.SSE
  alias BeamWeaver.Stream
  alias BeamWeaver.Stream.Events
  alias BeamWeaver.ZAI.Error
  alias BeamWeaver.ZAI.Messages, as: ZAIMessages

  @spec text_deltas(binary() | [map()] | term()) :: [String.t()]
  def text_deltas(body) when is_binary(body), do: body |> SSE.events() |> text_deltas()

  def text_deltas(events) when is_list(events) do
    events
    |> Enum.flat_map(fn
      %{"data" => %{"choices" => choices}} when is_list(choices) ->
        Enum.flat_map(choices, fn choice ->
          case get_in(choice, ["delta", "content"]) do
            text when is_binary(text) -> [text]
            _other -> []
          end
        end)

      _event ->
        []
    end)
  end

  def text_deltas(_body), do: []

  @spec typed_events(binary() | [map()] | term()) :: [Stream.Envelope.t()]
  def typed_events(body) when is_binary(body), do: body |> SSE.events() |> typed_events()

  def typed_events(events) when is_list(events) do
    chunk_events =
      events
      |> message_chunks()
      |> Enum.flat_map(&chunk_to_events/1)

    done_events = Enum.flat_map(events, &done_event/1)

    (chunk_events ++ done_events)
    |> Enum.map(&ensure_envelope/1)
  end

  def typed_events(_body), do: []

  @spec stream_body_to_message(binary(), keyword()) ::
          {:ok, BeamWeaver.Core.Message.t()} | {:error, Error.t()}
  def stream_body_to_message(body, opts \\ [])

  def stream_body_to_message(body, opts) when is_binary(body) do
    events = SSE.events(body)
    chunks = message_chunks(events)

    case MessageChunk.merge_many(chunks) do
      nil ->
        {:error, Error.new(:invalid_response, "Z.ai chat-completions stream had no chunks")}

      chunk ->
        message = MessageChunk.to_message(chunk)
        usage = stream_usage(events)
        finish_reason = stream_finish_reason(events)
        metadata = stream_metadata(events, message, opts)

        {:ok,
         %{
           message
           | id: message.id || metadata[:id],
             usage_metadata: usage,
             status: finish_reason,
             metadata: Map.merge(message.metadata, metadata),
             response_metadata:
               message.response_metadata
               |> Map.merge(metadata)
               |> Map.merge(%{usage: usage, finish_reason: finish_reason})
               |> MessageParts.reject_nil_values()
         }}
    end
  end

  def stream_body_to_message(_body, _opts) do
    {:error, Error.new(:invalid_response, "Z.ai chat-completions stream body must be binary")}
  end

  defp message_chunks(events) when is_list(events) do
    events
    |> Enum.reduce(%{chunks: []}, &apply_message_chunk_event/2)
    |> Map.fetch!(:chunks)
    |> Enum.reverse()
  end

  defp apply_message_chunk_event(%{"data" => %{"id" => id, "choices" => choices}}, state)
       when is_list(choices) do
    Enum.reduce(choices, state, fn choice, acc ->
      delta = choice["delta"] || %{}

      acc
      |> maybe_emit_reasoning(delta, id)
      |> maybe_emit_content(delta, id)
      |> maybe_emit_tool_calls(delta, id)
      |> maybe_emit_unknown_delta(delta, id)
    end)
  end

  defp apply_message_chunk_event(_event, state), do: state

  defp maybe_emit_reasoning(state, %{"reasoning_content" => reasoning}, id)
       when is_binary(reasoning) do
    emit_message_chunk(
      state,
      Messages.ai_chunk([%{type: :reasoning, reasoning: reasoning, index: 0}],
        id: id,
        metadata: %{reasoning_content: reasoning}
      )
    )
  end

  defp maybe_emit_reasoning(state, _delta, _id), do: state

  defp maybe_emit_content(state, %{"content" => content}, id) when is_binary(content),
    do: emit_message_chunk(state, Messages.ai_chunk(content, id: id))

  defp maybe_emit_content(state, _delta, _id), do: state

  defp maybe_emit_tool_calls(state, %{"tool_calls" => calls}, id) when is_list(calls) do
    Enum.reduce(calls, state, fn call, acc ->
      function = call["function"] || %{}

      emit_message_chunk(
        acc,
        Messages.ai_chunk("",
          id: id,
          tool_call_chunks: [
            Messages.tool_call_chunk(
              id: call["id"],
              index: call["index"],
              name: function["name"],
              args: function["arguments"] || ""
            )
          ]
        )
      )
    end)
  end

  defp maybe_emit_tool_calls(state, _delta, _id), do: state

  defp maybe_emit_unknown_delta(state, delta, id) when is_map(delta) do
    unknown = Map.drop(delta, ["content", "reasoning_content", "tool_calls", "role"])

    if unknown == %{} do
      state
    else
      emit_message_chunk(state, Messages.ai_chunk("", id: id, metadata: %{zai_delta: unknown}))
    end
  end

  defp emit_message_chunk(state, chunk), do: Map.update!(state, :chunks, &[chunk | &1])

  defp chunk_to_events(%Messages.AIChunk{} = chunk) do
    token_events =
      if is_binary(chunk.content) and chunk.content != "" do
        [%Events.Token{text: chunk.content}]
      else
        []
      end

    reasoning? = reasoning_chunk?(chunk)
    tool_call_events = Enum.map(chunk.tool_call_chunks || [], &%Events.ToolCallChunk{chunk: &1})

    metadata =
      if reasoning? do
        %{provider: :zai, block_type: :reasoning}
      else
        %{provider: :zai}
      end

    events = token_events ++ tool_call_events ++ [%Events.MessageChunk{chunk: chunk}]
    Enum.map(events, &Stream.envelope(&1, metadata: metadata))
  end

  defp chunk_to_events(chunk),
    do: [Stream.envelope(%Events.MessageChunk{chunk: chunk}, metadata: %{provider: :zai})]

  defp reasoning_chunk?(%Messages.AIChunk{content: content}) when is_list(content) do
    Enum.any?(content, fn
      %{"type" => "reasoning"} -> true
      %{type: :reasoning} -> true
      _block -> false
    end)
  end

  defp reasoning_chunk?(_chunk), do: false

  defp done_event(%{"data" => %{"usage" => usage} = data}) when is_map(usage) do
    [%Events.Done{result: data, usage: usage}]
  end

  defp done_event(%{"data" => %{"choices" => choices}}) when is_list(choices) do
    if Enum.any?(choices, &(get_in(&1, ["finish_reason"]) != nil)),
      do: [%Events.Done{result: nil}],
      else: []
  end

  defp done_event(_event), do: []

  defp ensure_envelope(%Stream.Envelope{} = envelope), do: envelope
  defp ensure_envelope(event), do: Stream.envelope(event, metadata: %{provider: :zai})

  defp stream_usage(events) do
    events
    |> Enum.reduce(nil, fn
      %{"data" => %{"usage" => usage}}, _acc when is_map(usage) ->
        ZAIMessages.usage_metadata(%{"usage" => usage})

      _event, acc ->
        acc
    end)
  end

  defp stream_finish_reason(events) do
    events
    |> Enum.find_value(fn
      %{"data" => %{"choices" => choices}} when is_list(choices) ->
        Enum.find_value(choices, & &1["finish_reason"])

      _event ->
        nil
    end)
  end

  defp stream_metadata(events, message, opts) do
    reasoning_content = reasoning_content(message)
    header_metadata = Keyword.get(opts, :header_metadata, %{})
    decoded_headers = header_metadata[:headers] || %{}
    x_log_id = decoded_headers[:x_log_id]

    events
    |> Enum.reduce(%{model_provider: "zai", provider: :zai, api: :chat_completions}, fn
      %{"data" => data}, acc when is_map(data) ->
        choice = first_choice(data)
        id = data["id"] || acc[:id] || x_log_id

        acc
        |> put_optional(:id, id)
        |> put_optional(:request_id, data["request_id"] || id)
        |> put_optional(:x_log_id, x_log_id)
        |> put_optional(:created, data["created"])
        |> put_optional(:object, data["object"])
        |> put_optional(:model, data["model"])
        |> put_optional(:model_name, data["model"])
        |> put_optional(:token_usage, data["usage"])
        |> put_optional(:finish_reason, choice && choice["finish_reason"])

      _event, acc ->
        acc
    end)
    |> put_optional(:reasoning_content, reasoning_content)
    |> put_optional(:headers, header_metadata[:headers])
    |> put_optional(:transport, transport_metadata(header_metadata))
    |> maybe_put_raw_headers(
      Keyword.get(opts, :raw_response_headers, []),
      Keyword.get(opts, :include_response_headers, false)
    )
  end

  defp maybe_put_raw_headers(metadata, _headers, false), do: metadata

  defp maybe_put_raw_headers(metadata, headers, true) do
    put_optional(metadata, :_beamweaver_response_headers, Map.new(headers))
  end

  defp transport_metadata(%{request_id: request_id}) when is_binary(request_id) and request_id != "" do
    %{request_id: request_id}
  end

  defp transport_metadata(_metadata), do: nil

  defp first_choice(%{"choices" => [choice | _rest]}) when is_map(choice), do: choice
  defp first_choice(_data), do: nil

  defp reasoning_content(message) do
    message.content
    |> List.wrap()
    |> Enum.flat_map(fn
      %{type: :reasoning, reasoning: text} when is_binary(text) -> [text]
      %{"type" => "reasoning", "reasoning" => text} when is_binary(text) -> [text]
      _block -> []
    end)
    |> Enum.join("")
    |> empty_to_nil()
  end

  defp empty_to_nil(""), do: nil
  defp empty_to_nil(value), do: value

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, _key, []), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)
end
