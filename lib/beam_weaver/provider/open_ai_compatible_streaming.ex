defmodule BeamWeaver.Provider.OpenAICompatibleStreaming do
  @moduledoc false

  alias BeamWeaver.Core.Messages
  alias BeamWeaver.Core.Messages.MessageChunk
  alias BeamWeaver.OpenAI.MessageParts
  alias BeamWeaver.OpenAI.Streaming.SSE
  alias BeamWeaver.Stream
  alias BeamWeaver.Stream.Events

  @type config :: %{
          required(:provider) => atom(),
          required(:provider_name) => String.t(),
          required(:error_module) => module(),
          required(:usage_metadata) => (map() -> map() | nil),
          required(:stream_metadata) => ([map()], BeamWeaver.Core.Message.t(), keyword() -> map()),
          optional(:choice_usage) => boolean(),
          optional(:include_chunk_id) => boolean(),
          optional(:reasoning_index) => non_neg_integer() | nil,
          optional(:unknown_delta_key) => atom()
        }

  @spec text_deltas(binary() | [map()] | term()) :: [String.t()]
  def text_deltas(body) when is_binary(body), do: body |> SSE.events() |> text_deltas()

  def text_deltas(events) when is_list(events) do
    Enum.flat_map(events, fn
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

  @spec typed_events(binary() | [map()] | term(), config()) :: [Stream.Envelope.t()]
  def typed_events(body, config) when is_binary(body),
    do: body |> SSE.events() |> typed_events(config)

  def typed_events(events, config) when is_list(events) do
    chunk_events =
      events
      |> message_chunks(config)
      |> Enum.flat_map(&chunk_to_events(&1, config))

    done_events = Enum.flat_map(events, &done_event(&1, config))

    Enum.map(chunk_events ++ done_events, &ensure_envelope(&1, config))
  end

  def typed_events(_body, _config), do: []

  @spec stream_body_to_message(binary() | term(), config(), keyword()) ::
          {:ok, BeamWeaver.Core.Message.t()} | {:error, term()}
  def stream_body_to_message(body, config, opts \\ [])

  def stream_body_to_message(body, config, opts) when is_binary(body) do
    events = SSE.events(body)
    chunks = message_chunks(events, config)

    case MessageChunk.merge_many(chunks) do
      nil ->
        {:error, error(config, :invalid_response, "#{config.provider_name} stream had no chunks")}

      chunk ->
        message = MessageChunk.to_message(chunk)
        usage = stream_usage(events, config)
        finish_reason = stream_finish_reason(events)
        metadata = config.stream_metadata.(events, message, opts)
        message = maybe_put_message_id(message, metadata, config)

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

  def stream_body_to_message(_body, config, _opts) do
    {:error, error(config, :invalid_response, "#{config.provider_name} stream body must be binary")}
  end

  defp message_chunks(events, config) do
    events
    |> Enum.reduce(%{chunks: [], id: nil}, &apply_message_chunk_event(&1, &2, config))
    |> Map.fetch!(:chunks)
    |> Enum.reverse()
  end

  defp apply_message_chunk_event(%{"data" => %{"choices" => choices} = data}, state, config)
       when is_list(choices) do
    id = data["id"] || state.id
    state = %{state | id: id}

    Enum.reduce(choices, state, fn choice, acc ->
      delta = choice["delta"] || %{}

      acc
      |> maybe_emit_reasoning(delta, id, config)
      |> maybe_emit_content(delta, id, config)
      |> maybe_emit_tool_calls(delta, id, config)
      |> maybe_emit_unknown_delta(delta, id, config)
    end)
  end

  defp apply_message_chunk_event(_event, state, _config), do: state

  defp maybe_emit_reasoning(state, %{"reasoning_content" => reasoning}, id, config)
       when is_binary(reasoning) do
    block =
      %{type: :reasoning, reasoning: reasoning}
      |> put_optional(:index, Map.get(config, :reasoning_index))

    emit_message_chunk(
      state,
      Messages.ai_chunk([block],
        id: chunk_id(id, config),
        metadata: %{reasoning_content: reasoning}
      )
    )
  end

  defp maybe_emit_reasoning(state, _delta, _id, _config), do: state

  defp maybe_emit_content(state, %{"content" => content}, id, config)
       when is_binary(content) do
    emit_message_chunk(state, Messages.ai_chunk(content, id: chunk_id(id, config)))
  end

  defp maybe_emit_content(state, _delta, _id, _config), do: state

  defp maybe_emit_tool_calls(state, %{"tool_calls" => calls}, id, config)
       when is_list(calls) do
    Enum.reduce(calls, state, fn call, acc ->
      function = call["function"] || %{}

      emit_message_chunk(
        acc,
        Messages.ai_chunk("",
          id: chunk_id(id, config),
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

  defp maybe_emit_tool_calls(state, _delta, _id, _config), do: state

  defp maybe_emit_unknown_delta(state, delta, id, config) when is_map(delta) do
    unknown = Map.drop(delta, ["content", "reasoning_content", "tool_calls", "role"])

    if unknown == %{} do
      state
    else
      metadata = %{Map.fetch!(config, :unknown_delta_key) => unknown}

      emit_message_chunk(
        state,
        Messages.ai_chunk("", id: chunk_id(id, config), metadata: metadata)
      )
    end
  end

  defp emit_message_chunk(state, chunk), do: Map.update!(state, :chunks, &[chunk | &1])

  defp chunk_to_events(%Messages.AIChunk{} = chunk, config) do
    token_events =
      if is_binary(chunk.content) and chunk.content != "" do
        [%Events.Token{text: chunk.content}]
      else
        []
      end

    tool_call_events = Enum.map(chunk.tool_call_chunks || [], &%Events.ToolCallChunk{chunk: &1})
    metadata = event_metadata(config, reasoning_chunk?(chunk))
    events = token_events ++ tool_call_events ++ [%Events.MessageChunk{chunk: chunk}]

    Enum.map(events, &Stream.envelope(&1, metadata: metadata))
  end

  defp chunk_to_events(chunk, config) do
    [Stream.envelope(%Events.MessageChunk{chunk: chunk}, metadata: event_metadata(config, false))]
  end

  defp event_metadata(config, true), do: %{provider: config.provider, block_type: :reasoning}
  defp event_metadata(config, false), do: %{provider: config.provider}

  defp reasoning_chunk?(%Messages.AIChunk{content: content}) when is_list(content) do
    Enum.any?(content, fn
      %{"type" => "reasoning"} -> true
      %{type: :reasoning} -> true
      _block -> false
    end)
  end

  defp reasoning_chunk?(_chunk), do: false

  defp done_event(%{"data" => %{"usage" => usage} = data}, _config) when is_map(usage) do
    [%Events.Done{result: data, usage: usage}]
  end

  defp done_event(%{"data" => %{"choices" => choices}}, config) when is_list(choices) do
    case Enum.find(choices, &(get_in(&1, ["finish_reason"]) != nil)) do
      nil -> []
      choice -> [%Events.Done{result: nil, usage: choice_usage(choice, config)}]
    end
  end

  defp done_event(_event, _config), do: []

  defp choice_usage(choice, %{choice_usage: true}), do: choice["usage"]
  defp choice_usage(_choice, _config), do: nil

  defp ensure_envelope(%Stream.Envelope{} = envelope, _config), do: envelope

  defp ensure_envelope(event, config) do
    Stream.envelope(event, metadata: %{provider: config.provider})
  end

  defp stream_usage(events, config) do
    Enum.reduce(events, nil, fn
      %{"data" => %{"usage" => usage}}, _acc when is_map(usage) ->
        config.usage_metadata.(%{"usage" => usage})

      %{"data" => %{"choices" => choices}}, acc
      when is_list(choices) and config.choice_usage == true ->
        case Enum.find_value(choices, & &1["usage"]) do
          usage when is_map(usage) -> config.usage_metadata.(%{"usage" => usage})
          _other -> acc
        end

      _event, acc ->
        acc
    end)
  end

  defp stream_finish_reason(events) do
    Enum.find_value(events, fn
      %{"data" => %{"choices" => choices}} when is_list(choices) ->
        Enum.find_value(choices, & &1["finish_reason"])

      _event ->
        nil
    end)
  end

  defp maybe_put_message_id(message, metadata, %{include_chunk_id: true}) do
    %{message | id: message.id || metadata[:id]}
  end

  defp maybe_put_message_id(message, _metadata, _config), do: message

  defp chunk_id(id, %{include_chunk_id: true}), do: id
  defp chunk_id(_id, _config), do: nil

  defp error(config, type, message) do
    apply(config.error_module, :new, [type, message])
  end

  defp put_optional(map, _key, nil), do: map
  defp put_optional(map, key, value), do: Map.put(map, key, value)
end
