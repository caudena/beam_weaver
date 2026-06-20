defmodule BeamWeaver.Anthropic.Streaming do
  @moduledoc false

  alias BeamWeaver.Anthropic.Messages
  alias BeamWeaver.Core.Messages, as: CoreMessages
  alias BeamWeaver.Provider.Options
  alias BeamWeaver.Provider.SSE
  alias BeamWeaver.Stream
  alias BeamWeaver.Stream.Events

  @spec text_deltas(binary() | [map()] | term()) :: [String.t()]
  def text_deltas(body) when is_binary(body), do: body |> SSE.events() |> text_deltas()

  def text_deltas(events) when is_list(events) do
    events
    |> Enum.flat_map(fn
      %{
        "data" => %{
          "type" => "content_block_delta",
          "delta" => %{"type" => "text_delta", "text" => text}
        }
      }
      when is_binary(text) ->
        [text]

      _event ->
        []
    end)
  end

  def text_deltas(_body), do: []

  @spec response(binary() | [map()] | term()) :: map()
  def response(body) when is_binary(body), do: body |> SSE.events() |> response()

  def response(events) when is_list(events) do
    state =
      Enum.reduce(events, initial_state(), fn event, state ->
        apply_event(event["data"] || %{}, state)
      end)

    response =
      state.response
      |> Map.put("content", content_blocks(state))
      |> put_usage(state.usage)

    Map.merge(response, state.message_delta)
  end

  def response(_body), do: %{"content" => []}

  @spec lifecycle_events(binary() | [map()] | term()) :: [map()]
  def lifecycle_events(body) when is_binary(body), do: body |> SSE.events() |> lifecycle_events()

  def lifecycle_events(events) when is_list(events) do
    Enum.map(events, fn event -> event["data"] || event end)
  end

  def lifecycle_events(_body), do: []

  @spec typed_events(binary() | [map()] | term()) :: [Stream.Envelope.t()]
  def typed_events(body) when is_binary(body), do: body |> SSE.events() |> typed_events()

  def typed_events(events) when is_list(events) do
    {envelopes, _state} =
      Enum.map_reduce(events, %{block_start: %{}}, fn event, state ->
        typed_event(event["data"] || %{}, state)
      end)

    envelopes
    |> List.flatten()
    |> Enum.map(&Stream.envelope(&1, metadata: %{provider: :anthropic}))
  end

  def typed_events(_body), do: []

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
      |> maybe_put("context_management", event["context_management"])

    %{
      state
      | usage: Map.merge(state.usage, usage || %{}),
        message_delta: Map.merge(state.message_delta, message_delta)
    }
  end

  defp apply_event(_event, state), do: state

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

  defp finalize_block(%{"type" => "tool_use", "partial_json" => partial_json} = block)
       when is_binary(partial_json) do
    case BeamWeaver.JSON.decode(partial_json) do
      {:ok, decoded} when is_map(decoded) -> Map.put(block, "input", decoded)
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

  defp typed_event(%{"type" => "message_start", "message" => %{"model" => model}}, state) do
    {
      [
        %Events.MessageChunk{chunk: CoreMessages.ai_chunk("", metadata: %{model_name: model})}
      ],
      state
    }
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
    start_block = get_in(state, [:block_start, index]) || %{}

    tool_chunk =
      CoreMessages.tool_call_chunk(id: nil, index: index, name: nil, args: partial_json)

    content = [
      %{type: :input_json_delta, partial_json: partial_json, index: index}
    ]

    content =
      if start_block["type"] == "tool_use" do
        content
      else
        [%{type: :server_tool_call_chunk, args: partial_json, index: index}]
      end

    chunk =
      CoreMessages.ai_chunk(content,
        tool_call_chunks: if(start_block["type"] == "tool_use", do: [tool_chunk], else: [])
      )

    events =
      if start_block["type"] == "tool_use",
        do: [%Events.ToolCallChunk{chunk: tool_chunk}],
        else: []

    {events ++ [%Events.MessageChunk{chunk: chunk}], state}
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

  defp typed_event(
         %{"type" => "message_delta", "delta" => delta, "usage" => usage} = event,
         state
       ) do
    response_metadata =
      %{
        stop_reason: get_in(delta || %{}, ["stop_reason"]),
        stop_sequence: get_in(delta || %{}, ["stop_sequence"]),
        container: get_in(delta || %{}, ["container"]),
        context_management: event["context_management"]
      }
      |> Options.reject_nil_values()

    metadata = Map.put(response_metadata, :usage_metadata, Messages.usage_metadata(usage))

    {
      [
        %Events.MessageChunk{chunk: CoreMessages.ai_chunk("", metadata: metadata)},
        %Events.Done{result: delta, usage: usage}
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

  defp response_delta_block(%{"type" => "input_json_delta"} = block) do
    %{type: :input_json_delta, partial_json: block["partial_json"], index: block["index"], raw_provider_block: block}
    |> Options.reject_nil_values()
  end

  defp response_delta_block(%{"type" => type} = block) do
    %{type: type, index: block["index"], raw_provider_block: block}
    |> Options.reject_nil_values()
  end

  defp encode_args(nil), do: ""
  defp encode_args(args) when is_binary(args), do: args
  defp encode_args(args), do: BeamWeaver.JSON.encode!(args)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
