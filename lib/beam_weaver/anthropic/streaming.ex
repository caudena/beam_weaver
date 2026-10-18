defmodule BeamWeaver.Anthropic.Streaming do
  @moduledoc false

  import BeamWeaver.MapShape, only: [put_present: 3]

  alias BeamWeaver.Anthropic.Messages
  alias BeamWeaver.Core.Messages, as: CoreMessages
  alias BeamWeaver.Provider.OpenAICompatibleStreaming
  alias BeamWeaver.Provider.Options
  alias BeamWeaver.Provider.SSE
  alias BeamWeaver.Stream
  alias BeamWeaver.Stream.Events

  @spec text_deltas([map()]) :: [String.t()]
  def text_deltas(events) when is_list(events) do
    for %{"data" => %{"type" => "content_block_delta", "delta" => %{"type" => "text_delta", "text" => text}}}
        when is_binary(text) <- events,
        do: text
  end

  @spec response(binary() | [map()]) :: map()
  def response(body) when is_binary(body), do: body |> SSE.events() |> response()

  def response(events) when is_list(events),
    do: events |> Enum.reduce(initial_state(), &apply_event(&1["data"] || %{}, &2)) |> build_response()

  @spec lifecycle_events([map()]) :: [map()]
  def lifecycle_events(events) when is_list(events), do: Enum.map(events, &(&1["data"] || &1))

  @spec typed_events([map()], map() | nil) :: {[Stream.Envelope.t()], map()}
  def typed_events(events, state) when is_list(events) do
    {envelopes, state} = Enum.map_reduce(events, state || %{block_start: %{}}, &typed_event(&1["data"] || %{}, &2))
    {envelopes |> List.flatten() |> Enum.map(&Stream.envelope(&1, metadata: %{provider: :anthropic})), state}
  end

  # A live stream ends with the complete reply, the message `response/1`
  # decodes to, followed by one `Done` event. Until the stream closes, the
  # parser state also builds the reply and holds `Done` back, one for each
  # `message_delta`; `finish_typed_events/2` emits the reply and one `Done`
  # made of the held ones.
  @spec reply_typed_events([map()], map() | nil) :: {[Stream.Envelope.t()], map()}
  def reply_typed_events(events, state) when is_list(events) do
    %{parser: parser, reply: reply, done: done} = state || %{parser: nil, reply: initial_state(), done: []}
    {typed, parser} = typed_events(events, parser)
    {held, typed} = Enum.split_with(typed, &match?(%Stream.Envelope{event: %Events.Done{}}, &1))
    reply = Enum.reduce(events, reply, &apply_event(&1["data"] || %{}, &2))

    {typed, %{parser: parser, reply: reply, done: done ++ held}}
  end

  # `decode` turns the reply's response into its message. A stream without
  # message events has no reply.
  @spec finish_typed_events(map() | nil, (map() -> {:ok, BeamWeaver.Core.Message.t()} | {:error, term()})) ::
          {:ok, [Stream.Envelope.t()]} | {:error, term()}
  def finish_typed_events(nil, _decode), do: {:ok, []}

  def finish_typed_events(%{reply: reply, done: done}, decode) do
    done = OpenAICompatibleStreaming.merge_done(done)

    if reply == initial_state() do
      {:ok, done}
    else
      with {:ok, message} <- reply |> build_response() |> decode.() do
        {:ok, [Stream.envelope(%Events.Message{message: message}, metadata: %{provider: :anthropic}) | done]}
      end
    end
  end

  defp initial_state do
    %{
      response: %{"content" => []},
      blocks: %{},
      usage: %{},
      message_delta: %{}
    }
  end

  defp apply_event(%{"type" => "message_start", "message" => message}, state)
       when is_map(message) do
    usage = message["usage"] || %{}

    %{
      state
      | response: Map.drop(message, ["content", "usage"]),
        usage: Map.merge(state.usage, usage)
    }
  end

  defp apply_event(
         %{"type" => "content_block_start", "index" => index, "content_block" => block},
         state
       )
       when is_integer(index) and is_map(block) do
    put_in(state, [:blocks, index], Options.stringify_keys(block))
  end

  defp apply_event(%{"type" => "content_block_delta", "index" => index, "delta" => delta}, state)
       when is_integer(index) and is_map(delta) do
    update_in(state, [:blocks, index], fn block ->
      apply_delta(block || %{}, Options.stringify_keys(delta))
    end)
  end

  defp apply_event(%{"type" => "content_block_stop", "index" => index}, state)
       when is_integer(index) do
    update_in(state, [:blocks, index], &finalize_block/1)
  end

  defp apply_event(
         %{"type" => "message_delta", "delta" => delta, "usage" => usage} = event,
         state
       )
       when is_map(delta) do
    message_delta =
      delta
      |> Options.stringify_keys()
      |> Map.take(["stop_reason", "stop_details", "stop_sequence", "container"])
      |> Options.reject_nil_values()
      |> put_present("context_management", event["context_management"])
      |> put_present("input_transformations", event["input_transformations"])

    %{
      state
      | usage: Map.merge(state.usage, usage || %{}),
        message_delta: Map.merge(state.message_delta, message_delta)
    }
  end

  defp apply_event(_event, state), do: state

  defp build_response(state) do
    state.response
    |> Map.put("content", content_blocks(state))
    |> put_usage(state.usage)
    |> Map.merge(state.message_delta)
  end

  defp apply_delta(block, %{"type" => "text_delta", "text" => text}) do
    block
    |> Map.put_new("type", "text")
    |> Map.update("text", text || "", &((&1 || "") <> (text || "")))
  end

  defp apply_delta(block, %{"type" => "citations_delta", "citation" => citation}) do
    block
    |> Map.put_new("type", "text")
    |> Map.update("citations", [citation], &(&1 ++ [citation]))
  end

  defp apply_delta(block, %{"type" => "thinking_delta", "thinking" => thinking}) do
    block
    |> Map.put_new("type", "thinking")
    |> Map.update("thinking", thinking || "", &((&1 || "") <> (thinking || "")))
  end

  defp apply_delta(block, %{"type" => "signature_delta", "signature" => signature}) do
    block
    |> Map.put_new("type", "thinking")
    |> Map.put("signature", signature)
  end

  defp apply_delta(block, %{"type" => "input_json_delta", "partial_json" => partial_json}) do
    block
    |> Map.put_new("type", "input_json_delta")
    |> Map.update("partial_json", partial_json || "", &((&1 || "") <> (partial_json || "")))
  end

  defp apply_delta(block, %{"type" => "compaction_delta"} = delta) do
    delta
    |> Map.put("type", "compaction")
    |> Map.merge(block, fn _key, left, right -> right || left end)
  end

  defp apply_delta(block, delta), do: Map.merge(block, delta)

  # A finished tool block carries its input, decoded from the streamed JSON,
  # in the shape a later request sends back. A tool without input streams
  # empty JSON and keeps the input of its start block.
  defp finalize_block(%{"type" => type, "partial_json" => partial_json} = block)
       when type in ["tool_use", "server_tool_use", "mcp_tool_use"] and is_binary(partial_json) do
    case BeamWeaver.JSON.decode(partial_json) do
      {:ok, decoded} when is_map(decoded) -> block |> Map.put("input", decoded) |> Map.delete("partial_json")
      _other when partial_json == "" -> Map.delete(block, "partial_json")
      _other -> block
    end
  end

  defp finalize_block(block), do: block || %{}

  defp content_blocks(%{blocks: blocks}) do
    blocks
    |> Enum.sort_by(fn {index, _block} -> index end)
    |> Enum.map(fn {_index, block} -> block end)
  end

  defp put_usage(response, usage) when usage == %{}, do: response
  defp put_usage(response, usage), do: Map.put(response, "usage", usage)

  defp typed_event(%{"type" => "message_start", "message" => message}, state)
       when is_map(message) do
    metadata =
      message
      |> Messages.response_metadata()
      |> Map.put(:usage_metadata, Messages.usage_metadata(message["usage"]))

    {
      [
        %Events.MessageChunk{chunk: CoreMessages.ai_chunk("", metadata: metadata)}
      ],
      state
    }
  end

  defp typed_event(
         %{
           "type" => "content_block_start",
           "content_block" => %{"type" => "redacted_thinking"} = block
         },
         state
       ) do
    chunk = CoreMessages.ai_chunk([response_delta_block(block)])
    {[%Events.MessageChunk{chunk: chunk}], state}
  end

  defp typed_event(
         %{
           "type" => "content_block_start",
           "index" => index,
           "content_block" => %{"type" => "tool_use"} = block
         },
         state
       ) do
    chunk =
      CoreMessages.ai_chunk("",
        tool_call_chunks: [
          CoreMessages.tool_call_chunk(
            id: block["id"],
            index: index,
            name: block["name"],
            args: encode_args(block["input"])
          )
        ]
      )

    {
      [
        %Events.ToolCallChunk{chunk: hd(chunk.tool_call_chunks)},
        %Events.MessageChunk{chunk: chunk}
      ],
      put_in(state, [:block_start, index], block)
    }
  end

  defp typed_event(
         %{"type" => "content_block_start", "index" => index, "content_block" => block},
         state
       )
       when is_map(block) do
    chunk = CoreMessages.ai_chunk([block |> response_delta_block() |> Map.put(:index, index)])
    {[%Events.MessageChunk{chunk: chunk}], put_in(state, [:block_start, index], block)}
  end

  defp typed_event(
         %{
           "type" => "content_block_delta",
           "index" => index,
           "delta" => %{"type" => "text_delta", "text" => text}
         },
         state
       )
       when is_binary(text) do
    chunk = CoreMessages.ai_chunk(text, id: to_string(index))
    {[%Events.Token{text: text}, %Events.MessageChunk{chunk: chunk}], state}
  end

  defp typed_event(
         %{
           "type" => "content_block_delta",
           "index" => index,
           "delta" => %{"type" => "input_json_delta", "partial_json" => partial_json}
         },
         state
       )
       when is_binary(partial_json) do
    if get_in(state, [:block_start, index, "type"]) == "tool_use" do
      tool_chunk = CoreMessages.tool_call_chunk(index: index, args: partial_json)
      content = [%{type: :input_json_delta, partial_json: partial_json, index: index}]
      chunk = CoreMessages.ai_chunk(content, tool_call_chunks: [tool_chunk])
      {[%Events.ToolCallChunk{chunk: tool_chunk}, %Events.MessageChunk{chunk: chunk}], state}
    else
      chunk = CoreMessages.ai_chunk([%{type: :server_tool_call_chunk, args: partial_json, index: index}])
      {[%Events.MessageChunk{chunk: chunk}], state}
    end
  end

  defp typed_event(%{"type" => "content_block_delta", "index" => index, "delta" => delta}, state)
       when is_map(delta) do
    content =
      delta
      |> Options.stringify_keys()
      |> Map.put_new("index", index)
      |> normalize_delta_block()

    {[%Events.MessageChunk{chunk: CoreMessages.ai_chunk([content])}], state}
  end

  defp typed_event(%{"type" => "content_block_stop", "index" => index}, state)
       when is_integer(index) do
    {[], update_in(state, [:block_start], &Map.delete(&1, index))}
  end

  defp typed_event(
         %{"type" => "message_delta", "delta" => delta, "usage" => usage} = event,
         state
       ) do
    delta = delta || %{}

    response_metadata =
      %{
        stop_reason: delta["stop_reason"],
        stop_details: delta["stop_details"],
        stop_sequence: delta["stop_sequence"],
        container: delta["container"],
        context_management: event["context_management"],
        input_transformations: event["input_transformations"]
      }
      |> Options.reject_nil_values()

    metadata = Map.put(response_metadata, :usage_metadata, Messages.usage_metadata(usage))

    {
      [
        %Events.MessageChunk{chunk: CoreMessages.ai_chunk("", metadata: metadata)},
        %Events.Done{
          result:
            delta
            |> put_present("context_management", event["context_management"])
            |> put_present("input_transformations", event["input_transformations"]),
          usage: usage
        }
      ],
      state
    }
  end

  defp typed_event(_event, state), do: {[], state}

  defp normalize_delta_block(%{"type" => "thinking_delta", "thinking" => text} = block),
    do: block |> response_delta_block() |> Map.put(:type, :reasoning) |> Map.put(:reasoning, text)

  defp normalize_delta_block(%{"type" => "signature_delta"} = block),
    do: block |> response_delta_block() |> Map.put(:type, :reasoning)

  defp normalize_delta_block(%{"type" => "citations_delta", "citation" => citation} = block),
    do: block |> response_delta_block() |> Map.put(:type, :text) |> Map.put(:citations, [citation])

  defp normalize_delta_block(block), do: response_delta_block(block)

  defp response_delta_block(%{"type" => "text"} = block) do
    %{type: :text, text: block["text"], index: block["index"], raw_provider_block: block}
    |> Options.reject_nil_values()
  end

  defp response_delta_block(%{"type" => "thinking"} = block) do
    %{type: :reasoning, reasoning: block["thinking"], index: block["index"], raw_provider_block: block}
    |> Options.reject_nil_values()
  end

  defp response_delta_block(%{"type" => "redacted_thinking"} = block) do
    %{type: :redacted_thinking, raw_provider_block: block}
  end

  defp response_delta_block(%{"type" => "input_json_delta"} = block) do
    %{type: :input_json_delta, partial_json: block["partial_json"], index: block["index"], raw_provider_block: block}
    |> Options.reject_nil_values()
  end

  defp response_delta_block(%{"type" => type} = block) do
    %{type: type, index: block["index"], raw_provider_block: block}
    |> Options.reject_nil_values()
  end

  defp encode_args(nil), do: ""
  defp encode_args(args) when is_map(args) and map_size(args) == 0, do: ""
  defp encode_args(args) when is_binary(args), do: args
  defp encode_args(args), do: BeamWeaver.JSON.encode!(args)
end
