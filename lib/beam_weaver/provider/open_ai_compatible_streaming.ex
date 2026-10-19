defmodule BeamWeaver.Provider.OpenAICompatibleStreaming do
  @moduledoc false

  import BeamWeaver.MapShape, only: [put_present: 3]

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Messages
  alias BeamWeaver.Core.Messages.MessageChunk
  alias BeamWeaver.OpenAI.MessageParts
  alias BeamWeaver.Provider.SSE
  alias BeamWeaver.Stream
  alias BeamWeaver.Stream.Events

  @type config :: %{
          required(:provider) => atom(),
          optional(:provider_name) => String.t(),
          optional(:usage_metadata) => (map() -> map() | nil),
          optional(:stream_metadata) => ([map()], BeamWeaver.Core.Message.t(), keyword() -> map()),
          optional(:finish_message) => (BeamWeaver.Core.Message.t() -> BeamWeaver.Core.Message.t()),
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

    done_events =
      events
      |> Enum.flat_map(&done_event(&1, config))
      |> Enum.map(&Stream.envelope(&1, metadata: %{provider: config.provider}))

    chunk_events ++ merge_done(done_events)
  end

  def typed_events(_body, _config), do: []

  # A live stream is parsed batch by batch and ends with the complete reply.
  # Until the stream closes, the parser state keeps every event and holds the
  # `Done` events back, so that they follow the reply: `finish_typed_events/3`
  # emits the reply, then one `Done` made of the held ones (see
  # `merge_done/1`).
  @type stream_state :: %{events: [map()], done: [Stream.Envelope.t()]}

  @spec typed_events([map()], stream_state() | nil, config()) :: {[Stream.Envelope.t()], stream_state()}
  def typed_events(events, state, config) when is_list(events),
    do: events |> typed_events(config) |> hold_events(events, state)

  @spec hold_events([Stream.Envelope.t()], [map()], stream_state() | nil) ::
          {[Stream.Envelope.t()], stream_state()}
  def hold_events(typed, events, state) do
    %{events: seen, done: done} = state || %{events: [], done: []}
    {batch_done, typed} = Enum.split_with(typed, &match?(%Stream.Envelope{event: %Events.Done{}}, &1))

    {typed, %{events: Enum.reverse(events, seen), done: done ++ batch_done}}
  end

  # `reply` builds the complete reply from the stream's events; `:none` means
  # the stream had no reply to build.
  @spec finish_typed_events(
          stream_state() | nil,
          atom(),
          ([map()] -> {:ok, BeamWeaver.Core.Message.t()} | :none | {:error, term()})
        ) :: {:ok, [Stream.Envelope.t()]} | {:error, term()}
  def finish_typed_events(state, provider, reply) do
    %{events: seen, done: done} = state || %{events: [], done: []}
    done = merge_done(done)

    case reply.(Enum.reverse(seen)) do
      {:ok, message} ->
        {:ok, [Stream.envelope(%Events.Message{message: message}, metadata: %{provider: provider}) | done]}

      :none ->
        {:ok, done}

      {:error, _error} = error ->
        error
    end
  end

  # A stream ends with one `Done`, though a provider can send its parts in
  # separate events, such as the finish reason and, in a later chunk, the
  # usage. Each field keeps the last value the held events set, and their
  # metadata merge.
  @spec merge_done([Stream.Envelope.t()]) :: [Stream.Envelope.t()]
  def merge_done([]), do: []

  def merge_done(done) do
    event =
      done
      |> Enum.map(& &1.event)
      |> Enum.reduce(fn event, merged ->
        Map.merge(merged, event, fn
          :metadata, earlier, later -> Map.merge(earlier, later)
          _key, earlier, nil -> earlier
          _key, _earlier, later -> later
        end)
      end)

    [%{List.last(done) | event: event}]
  end

  @spec stream_body_to_message(binary() | term(), config(), keyword()) ::
          {:ok, BeamWeaver.Core.Message.t()} | {:error, term()}
  def stream_body_to_message(body, config, opts \\ [])

  def stream_body_to_message(body, config, opts) when is_binary(body) do
    case body |> SSE.events() |> events_to_message(config, opts) do
      {:ok, message} -> {:ok, message}
      :none -> {:error, Error.new(:invalid_response, "#{config.provider_name} stream had no chunks")}
    end
  end

  def stream_body_to_message(_body, config, _opts),
    do: {:error, Error.new(:invalid_response, "#{config.provider_name} stream body must be binary")}

  @spec events_to_message([map()], config(), keyword()) :: {:ok, BeamWeaver.Core.Message.t()} | :none
  def events_to_message(events, config, opts) do
    case events |> message_chunks(config) |> MessageChunk.merge_many() do
      nil ->
        :none

      chunk ->
        message = MessageChunk.to_message(chunk)
        usage = stream_usage(events, config)
        finish_reason = stream_finish_reason(events)
        metadata = config.stream_metadata.(events, message, opts)
        message = maybe_put_message_id(message, metadata, config)

        message = %{
          message
          | usage_metadata: usage,
            status: finish_reason,
            metadata: Map.merge(message.metadata, metadata),
            response_metadata:
              message.response_metadata
              |> Map.merge(metadata)
              |> Map.merge(%{usage: usage, finish_reason: finish_reason})
              |> MessageParts.reject_nil_values()
        }

        {:ok, Map.get(config, :finish_message, & &1).(message)}
    end
  end

  # The Chat Completions response a stream's events add up to: the latest
  # value of each top-level field, and for each choice its latest fields and a
  # message with the content, reasoning and tool-call arguments joined.
  @spec chat_completion([map()]) :: map()
  def chat_completion(events) when is_list(events) do
    {response, choices} =
      Enum.reduce(events, {%{}, %{}}, fn
        %{"data" => %{} = data}, {response, choices} ->
          choices = data |> Map.get("choices") |> List.wrap() |> Enum.reduce(choices, &put_choice/2)
          {put_fields(response, Map.delete(data, "choices")), choices}

        _event, acc ->
          acc
      end)

    choices =
      choices
      |> Enum.sort_by(fn {index, _choice} -> index end)
      |> Enum.map(fn {index, choice} -> finish_choice(index, choice) end)

    Map.put(response, "choices", choices)
  end

  defp put_choice(%{} = choice, choices) do
    index = choice["index"] || 0
    delta = choice["delta"] || %{}
    current = Map.get(choices, index, %{fields: %{}, message: %{}, tool_calls: %{}})

    message =
      Enum.reduce(delta, current.message, fn
        {key, text}, acc when key in ["content", "reasoning_content", "refusal"] -> append_text(acc, key, text)
        {"tool_calls", _calls}, acc -> acc
        {key, value}, acc -> put_present(acc, key, value)
      end)

    tool_calls = delta |> Map.get("tool_calls") |> List.wrap() |> Enum.reduce(current.tool_calls, &put_tool_call/2)

    Map.put(choices, index, %{
      fields: put_fields(current.fields, Map.drop(choice, ["index", "delta"])),
      message: message,
      tool_calls: tool_calls
    })
  end

  defp put_choice(_choice, choices), do: choices

  defp put_tool_call(%{} = call, calls) do
    function = call["function"] || %{}

    Map.update(calls, call["index"] || 0, put_tool_call_fields(%{"function" => %{}}, call, function), fn current ->
      put_tool_call_fields(current, call, function)
    end)
  end

  defp put_tool_call(_call, calls), do: calls

  defp put_tool_call_fields(current, call, function) do
    current
    |> put_present("id", call["id"])
    |> put_present("type", call["type"])
    |> Map.update!("function", fn current_function ->
      current_function
      |> put_present("name", function["name"])
      |> append_text("arguments", function["arguments"])
    end)
  end

  defp finish_choice(index, choice) do
    tool_calls =
      choice.tool_calls
      |> Enum.sort_by(fn {call_index, _call} -> call_index end)
      |> Enum.map(fn {_call_index, call} -> Map.put_new(call, "type", "function") end)

    message =
      choice.message
      |> Map.put_new("role", "assistant")
      |> BeamWeaver.MapShape.put_optional("tool_calls", tool_calls)

    choice.fields
    |> Map.put("index", index)
    |> Map.put("message", message)
  end

  # Keeps each field's latest value; log probabilities add up token by token.
  defp put_fields(fields, values) do
    Enum.reduce(values, fields, fn
      {_key, nil}, acc -> acc
      {"logprobs", logprobs}, acc -> Map.update(acc, "logprobs", logprobs, &join_logprobs(&1, logprobs))
      {key, value}, acc -> Map.put(acc, key, value)
    end)
  end

  defp join_logprobs(%{} = current, %{} = logprobs) do
    Map.merge(current, logprobs, fn
      _key, left, right when is_list(left) and is_list(right) -> left ++ right
      _key, _left, right -> right
    end)
  end

  defp join_logprobs(_current, logprobs), do: logprobs

  defp append_text(map, key, text) when is_binary(text), do: Map.update(map, key, text, &(&1 <> text))
  defp append_text(map, _key, _text), do: map

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
      |> put_present(:index, Map.get(config, :reasoning_index))

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

    tool_call_events = Enum.map(chunk.tool_call_chunks, &%Events.ToolCallChunk{chunk: &1})
    metadata = event_metadata(config, reasoning_chunk?(chunk))
    events = token_events ++ tool_call_events ++ [%Events.MessageChunk{chunk: chunk}]

    Enum.map(events, &Stream.envelope(&1, metadata: metadata))
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
end
