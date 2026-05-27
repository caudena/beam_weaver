defmodule BeamWeaver.Moonshot.Streaming do
  @moduledoc false

  alias BeamWeaver.Core.Messages
  alias BeamWeaver.Core.Messages.MessageChunk
  alias BeamWeaver.Moonshot.Error
  alias BeamWeaver.Moonshot.Messages, as: MoonshotMessages
  alias BeamWeaver.OpenAI.MessageParts
  alias BeamWeaver.OpenAI.Streaming.SSE
  alias BeamWeaver.Stream
  alias BeamWeaver.Stream.Events

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

  @spec stream_body_to_message(binary()) ::
          {:ok, BeamWeaver.Core.Message.t()} | {:error, Error.t()}
  def stream_body_to_message(body) when is_binary(body) do
    events = SSE.events(body)
    chunks = message_chunks(events)

    case MessageChunk.merge_many(chunks) do
      nil ->
        {:error, Error.new(:invalid_response, "Moonshot chat-completions stream had no chunks")}

      chunk ->
        message = MessageChunk.to_message(chunk)
        usage = stream_usage(events)
        finish_reason = stream_finish_reason(events)
        metadata = stream_metadata(events, message)

        {:ok,
         %{
           message
           | usage_metadata: usage,
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

  def stream_body_to_message(_body) do
    {:error, Error.new(:invalid_response, "Moonshot chat-completions stream body must be binary")}
  end

  defp message_chunks(events) when is_list(events) do
    events
    |> Enum.reduce(%{chunks: []}, &apply_message_chunk_event/2)
    |> Map.fetch!(:chunks)
    |> Enum.reverse()
  end

  defp apply_message_chunk_event(%{"data" => %{"choices" => choices}}, state)
       when is_list(choices) do
    Enum.reduce(choices, state, fn choice, acc ->
      delta = choice["delta"] || %{}

      acc
      |> maybe_emit_reasoning(delta)
      |> maybe_emit_content(delta)
      |> maybe_emit_tool_calls(delta)
      |> maybe_emit_unknown_delta(delta)
    end)
  end

  defp apply_message_chunk_event(_event, state), do: state

  defp maybe_emit_reasoning(state, %{"reasoning_content" => reasoning})
       when is_binary(reasoning) do
    emit_message_chunk(
      state,
      Messages.ai_chunk([%{type: :reasoning, reasoning: reasoning}],
        metadata: %{reasoning_content: reasoning}
      )
    )
  end

  defp maybe_emit_reasoning(state, _delta), do: state

  defp maybe_emit_content(state, %{"content" => content}) when is_binary(content),
    do: emit_message_chunk(state, Messages.ai_chunk(content))

  defp maybe_emit_content(state, _delta), do: state

  defp maybe_emit_tool_calls(state, %{"tool_calls" => calls}) when is_list(calls) do
    Enum.reduce(calls, state, fn call, acc ->
      function = call["function"] || %{}

      emit_message_chunk(
        acc,
        Messages.ai_chunk("",
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

  defp maybe_emit_tool_calls(state, _delta), do: state

  defp maybe_emit_unknown_delta(state, delta) when is_map(delta) do
    unknown = Map.drop(delta, ["content", "reasoning_content", "tool_calls", "role"])

    if unknown == %{} do
      state
    else
      emit_message_chunk(state, Messages.ai_chunk("", metadata: %{moonshot_delta: unknown}))
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

    tool_call_events =
      Enum.map(chunk.tool_call_chunks || [], &%Events.ToolCallChunk{chunk: &1})

    metadata =
      if reasoning? do
        %{provider: :moonshot, block_type: :reasoning}
      else
        %{provider: :moonshot}
      end

    events = token_events ++ tool_call_events ++ [%Events.MessageChunk{chunk: chunk}]
    Enum.map(events, &Stream.envelope(&1, metadata: metadata))
  end

  defp chunk_to_events(chunk),
    do: [Stream.envelope(%Events.MessageChunk{chunk: chunk}, metadata: %{provider: :moonshot})]

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

  defp ensure_envelope(event),
    do: Stream.envelope(event, metadata: %{provider: :moonshot})

  defp stream_usage(events) do
    events
    |> Enum.reduce(nil, fn
      %{"data" => %{"usage" => usage}}, _acc when is_map(usage) ->
        MoonshotMessages.usage_metadata(%{"usage" => usage})

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

  defp stream_metadata(events, message) do
    reasoning_content = reasoning_content(message)

    events
    |> Enum.reduce(%{model_provider: "moonshot", provider: :moonshot}, fn
      %{"data" => data}, acc when is_map(data) ->
        choice = first_choice(data)

        acc
        |> put_optional(:id, data["id"])
        |> put_optional(:model, data["model"])
        |> put_optional(:model_name, data["model"])
        |> put_optional(:system_fingerprint, data["system_fingerprint"])
        |> put_optional(:service_tier, data["service_tier"])
        |> put_optional(:token_usage, data["usage"])
        |> put_optional(:logprobs, choice && choice["logprobs"])

      _event, acc ->
        acc
    end)
    |> put_optional(:reasoning_content, reasoning_content)
  end

  defp first_choice(%{"choices" => [choice | _rest]}) when is_map(choice), do: choice
  defp first_choice(_data), do: nil

  defp reasoning_content(%{content: content}) when is_list(content) do
    content
    |> Enum.flat_map(fn
      %{"type" => "reasoning", "reasoning" => text} when is_binary(text) -> [text]
      %{type: :reasoning, reasoning: text} when is_binary(text) -> [text]
      _block -> []
    end)
    |> Enum.join("")
    |> empty_to_nil()
  end

  defp reasoning_content(_message), do: nil

  defp empty_to_nil(""), do: nil
  defp empty_to_nil(value), do: value

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, _key, []), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)
end
