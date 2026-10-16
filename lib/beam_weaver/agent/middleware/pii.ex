defmodule BeamWeaver.Agent.Middleware.PII do
  @moduledoc """
  Detects and edits common PII in the text of agent messages.

  Each middleware instance is one rule: it detects one or more PII types and
  blocks, redacts, masks, or hashes the matches. A rule edits the text of
  messages at three points:

    * `:apply_to_input` - the latest user message, before the model call
      (`true` by default).
    * `:apply_to_tool_results` - the tool results after the last assistant
      message, before the model reads them (`false` by default).
    * `:apply_to_output` - the messages a model call adds, before they are
      saved, including the failed answers `StructuredOutputRetry` keeps
      (`false` by default).

  A message's text is its content when that is a string, or the `text` of
  each of its content blocks. A rule leaves the rest as it is: tool-call
  arguments, reasoning, images and files, the agent's structured response,
  a tool's artifact, and the metadata a reply keeps, such as the provider's
  raw response. `stream_transform/1` edits what a stream shows, tool-call
  arguments and reasoning included. To protect saved threads, encrypt them
  with `BeamWeaver.Serialization.Encrypted`.

  Options:

    * `:type` - the kind of data: `:email`, `:credit_card`, `:ip`,
      `:mac_address`, `:url`, or a name of your own with `:detector`. Without
      it, one rule checks every built-in type.
    * `:strategy` - `:redact` (the default), `:mask`, `:hash` or `:block`,
      which fails the call with a `:pii_detected` error.
    * `:detector` - a regex string, or a function that returns the matches,
      for a type of your own.
    * `:apply_to_input`, `:apply_to_tool_results`, `:apply_to_output` - see
      above.
  """

  use BeamWeaver.Agent.Middleware

  alias BeamWeaver.Agent.Middleware.Helpers
  alias BeamWeaver.Agent.Middleware.PII.Detector
  alias BeamWeaver.Agent.ModelRequest
  alias BeamWeaver.Agent.ModelResponse
  alias BeamWeaver.Agent.State
  alias BeamWeaver.Core.ContentBlock
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Messages.AIChunk
  alias BeamWeaver.Core.Messages.InvalidToolCall
  alias BeamWeaver.Core.Messages.ToolCall
  alias BeamWeaver.Core.Messages.ToolCallChunk
  alias BeamWeaver.Graph.Overwrite
  alias BeamWeaver.Options
  alias BeamWeaver.Stream.Envelope
  alias BeamWeaver.Stream.Events

  @default_detectors [:email, :credit_card, :ip, :mac_address, :url]
  @strategies [:block, :redact, :mask, :hash]
  @stream_tail_graphemes 512
  @content_blocks [
    ContentBlock.Text,
    ContentBlock.PlainText,
    ContentBlock.Image,
    ContentBlock.Audio,
    ContentBlock.File,
    ContentBlock.Video,
    ContentBlock.Reasoning,
    ContentBlock.Citation,
    ContentBlock.ToolResult,
    ContentBlock.Unknown
  ]

  defstruct pii_type: nil,
            detectors: @default_detectors,
            detector: nil,
            strategy: :redact,
            replacement: nil,
            custom: [],
            apply_to_input: true,
            apply_to_output: false,
            apply_to_tool_results: false

  @type t :: %__MODULE__{}

  def new(opts \\ []) do
    opts =
      case opts do
        type when is_atom(type) or is_binary(type) -> [type: type]
        opts when is_list(opts) -> opts
      end

    pii_type = Keyword.get(opts, :type, Keyword.get(opts, :pii_type))
    detector = Keyword.get(opts, :detector)

    detectors =
      Keyword.get(opts, :detectors, if(pii_type, do: [pii_type], else: @default_detectors))

    strategy = Keyword.get(opts, :strategy, :redact) |> normalize_strategy!()

    Detector.validate_detector_config!(pii_type, detector, detectors)

    %__MODULE__{
      pii_type: Detector.normalize_type(pii_type),
      detectors: Enum.map(List.wrap(detectors), &Detector.normalize_detector/1),
      detector: detector,
      strategy: strategy,
      replacement: Keyword.get(opts, :replacement),
      custom: Keyword.get(opts, :custom, []),
      apply_to_input: Keyword.get(opts, :apply_to_input, true),
      apply_to_output: Keyword.get(opts, :apply_to_output, false),
      apply_to_tool_results: Keyword.get(opts, :apply_to_tool_results, false)
    }
  end

  @impl true
  def name(%__MODULE__{pii_type: nil, detectors: detectors}),
    do: "pii[#{Enum.map_join(detectors, ",", &Detector.detector_type/1)}]"

  def name(%__MODULE__{pii_type: pii_type}), do: "pii[#{pii_type}]"

  @impl true
  def before_model(%__MODULE__{apply_to_input: false, apply_to_tool_results: false}, _state, _runtime), do: nil

  def before_model(%__MODULE__{} = middleware, state, _runtime) do
    messages = State.messages(state)

    with {:ok, edited} <- edit_input(messages, middleware),
         {:ok, edited} <- edit_tool_results(edited, middleware) do
      if edited != messages, do: %{messages: Overwrite.new(edited)}
    end
  end

  # Output rules edit the model's reply inside the model call, so it is saved,
  # checkpointed and seen by later hooks only in its edited form.
  @impl true
  def wrap_model_call(%__MODULE__{apply_to_output: false}, %ModelRequest{} = request, handler),
    do: handler.(request)

  def wrap_model_call(%__MODULE__{} = middleware, %ModelRequest{} = request, handler) do
    case handler.(request) do
      {:ok, %ModelResponse{messages: messages} = response} ->
        with {:ok, messages} <- edit_all(messages, &edit_message(&1, middleware)),
             do: {:ok, %{response | messages: messages}}

      # A reply that failed the structured-output checks travels in the
      # error; `StructuredOutputRetry` saves it with the retry.
      {:error, %Error{details: %{failed_reply: %Message{} = reply} = details} = error} ->
        with {:ok, reply} <- edit_message(reply, middleware),
             do: {:error, %{error | details: %{details | failed_reply: reply}}}

      result ->
        result
    end
  end

  @doc """
  Detects email addresses and returns match maps with byte offsets.
  """
  defdelegate detect_email(content), to: Detector

  @doc """
  Detects Luhn-valid credit-card numbers in common 16-digit formats.
  """
  defdelegate detect_credit_card(content), to: Detector

  @doc """
  Detects valid IPv4 addresses.
  """
  defdelegate detect_ip(content), to: Detector

  @doc """
  Detects colon- or dash-separated MAC addresses.
  """
  defdelegate detect_mac_address(content), to: Detector

  @doc """
  Detects http/https URLs, www-hosts, and bare domains with paths.
  """
  defdelegate detect_url(content), to: Detector

  @doc """
  Returns a stream transform that applies the rule to what a stream shows.

  The transform is a `{fun, state}` pair: `fun.(event, state)` returns
  `{{:ok, event_or_events}, state}`, or `{{:error, error}, state}` for the
  `:block` strategy, and `BeamWeaver.Stream.MessagesTransformer` takes it as
  `pre_projection:`. It edits the events, never the saved thread:

    * the text and reasoning a model streams (`Token` and `MessageChunk`) and
      the tool-call arguments it streams (`ToolCallChunk`, and the tool-call
      chunks of a `MessageChunk`);
    * a whole `Message`: its content, reasoning included, and the arguments
      of its tool calls;
    * tool events: the input of `ToolStart`, the output a tool streams
      (`ToolDelta`), and the output of `ToolFinish` and message of
      `ToolError`;
    * state snapshots (`GraphValue`).

  It holds back the last 512 characters of each stream of text, so a value
  split across chunks is still caught, and emits them when the model's reply
  ends (`Done`, `Message` or `Error`), when the model call fails (a `Debug`
  event with `type: :model_call_failed`), or, for a tool's output, when the
  tool finishes. `Token` and `MessageChunk` events carry the same text in
  separate streams and are held back separately, so a whole agent stream can
  pass through it. Other events pass through as they are, such as `Custom`
  events and the raw result a `Done` event can carry.
  """
  @spec stream_transform(t() | keyword()) :: {(term(), list() -> {term(), list()}), list()}
  def stream_transform(%__MODULE__{} = middleware),
    do: {&redact_stream_event(middleware, &1, &2), []}

  def stream_transform(opts) when is_list(opts), do: opts |> new() |> stream_transform()

  defp edit_input(messages, %__MODULE__{apply_to_input: true} = middleware) do
    case Helpers.last_role_index(messages, :user) do
      nil -> {:ok, messages}
      index -> edit_at(messages, index, middleware)
    end
  end

  defp edit_input(messages, _middleware), do: {:ok, messages}

  # The tool results the model hasn't read yet: those after the last
  # assistant message.
  defp edit_tool_results(messages, %__MODULE__{apply_to_tool_results: true} = middleware) do
    case Helpers.last_role_index(messages, :assistant) do
      nil ->
        {:ok, messages}

      last ->
        {read, unread} = Enum.split(messages, last + 1)
        with {:ok, unread} <- edit_all(unread, &edit_tool_result(&1, middleware)), do: {:ok, read ++ unread}
    end
  end

  defp edit_tool_results(messages, _middleware), do: {:ok, messages}

  defp edit_tool_result(%Message{role: :tool} = message, middleware), do: edit_message(message, middleware)
  defp edit_tool_result(message, _middleware), do: {:ok, message}

  defp edit_at(messages, index, middleware) do
    with {:ok, message} <- edit_message(Enum.at(messages, index), middleware),
         do: {:ok, List.replace_at(messages, index, message)}
  end

  # A message's text: its content when that is a string, or the `text` of
  # each content block.
  defp edit_message(%Message{content: text} = message, middleware) when is_binary(text) do
    with {:ok, text} <- edit_text(text, middleware), do: {:ok, %{message | content: text}}
  end

  defp edit_message(%Message{content: blocks} = message, middleware) when is_list(blocks) do
    with {:ok, blocks} <- edit_all(blocks, &edit_block_text(&1, middleware)), do: {:ok, %{message | content: blocks}}
  end

  defp edit_message(message, _middleware), do: {:ok, message}

  defp edit_block_text(text, middleware) when is_binary(text), do: edit_text(text, middleware)

  defp edit_block_text(%{} = block, middleware) do
    case map_get(block, :text) do
      text when is_binary(text) ->
        with {:ok, edited} <- edit_text(text, middleware), do: {:ok, put_map_value(block, :text, edited)}

      _other ->
        {:ok, block}
    end
  end

  defp edit_block_text(block, _middleware), do: {:ok, block}

  defp redact_stream_event(middleware, event, pending) do
    case stream_slots(event) do
      [] -> redact_stream_value(middleware, event, pending)
      slots -> redact_stream_slots(middleware, event, slots, pending)
    end
  end

  # The text an event streams, as `{lane, text, put, alone}` slots. A lane is
  # one model call's (or tool's) stream of one kind of text, `put.(event,
  # text)` puts the edited text back into the event, and `alone.(text)` makes
  # an event that carries only that text, for the tail the lane holds back. A
  # tool-call chunk without an index is a call of its own: its slot has no
  # lane, and its text is edited at once.
  defp stream_slots(%Envelope{event: %Events.Token{text: text}} = envelope) when is_binary(text) do
    put = fn envelope, text -> update_event(envelope, &%{&1 | text: text}) end
    [{{:token, stream_source(envelope)}, text, put, &put.(envelope, &1)}]
  end

  defp stream_slots(%Envelope{event: %Events.MessageChunk{chunk: %AIChunk{} = chunk}} = envelope),
    do: chunk_content_slots(envelope, chunk) ++ chunk_args_slots(envelope, chunk)

  defp stream_slots(%Envelope{event: %Events.ToolCallChunk{chunk: %ToolCallChunk{args: args} = call}} = envelope)
       when is_binary(args) do
    put = fn envelope, text -> update_event(envelope, &%{&1 | chunk: %{&1.chunk | args: text}}) end
    [{args_lane(:tool_call_chunk, call, envelope), args, put, &put.(envelope, &1)}]
  end

  defp stream_slots(%Envelope{event: %Events.ToolDelta{delta: delta, tool_call_id: id}} = envelope)
       when is_binary(delta) do
    put = fn envelope, text -> update_event(envelope, &%{&1 | delta: text}) end
    [{{{:tool_delta, id}, stream_source(envelope)}, delta, put, &put.(envelope, &1)}]
  end

  # The protocol events `MessagesTransformer` reads, with string or atom keys.
  defp stream_slots(%{"params" => %{"data" => {%{} = payload, metadata}} = params} = event),
    do:
      protocol_slots(
        payload,
        protocol_source(params, metadata),
        &%{event | "params" => %{params | "data" => {&1, metadata}}}
      )

  defp stream_slots(%{params: %{data: {%{} = payload, metadata}} = params} = event),
    do: protocol_slots(payload, protocol_source(params, metadata), &%{event | params: %{params | data: {&1, metadata}}})

  defp stream_slots(_event), do: []

  defp chunk_content_slots(envelope, %AIChunk{content: text}) when is_binary(text) do
    put = fn envelope, text -> update_chunk(envelope, &%{&1 | content: text}) end
    alone = fn text -> update_chunk(envelope, &%{&1 | content: text, tool_call_chunks: []}) end
    [{{:chunk, stream_source(envelope)}, text, put, alone}]
  end

  defp chunk_content_slots(envelope, %AIChunk{content: blocks}) when is_list(blocks) do
    for {%{} = block, position} <- Enum.with_index(blocks),
        field <- [:text, :reasoning],
        text = map_get(block, field),
        is_binary(text) do
      put = fn envelope, text ->
        update_chunk(envelope, fn chunk ->
          %{chunk | content: List.update_at(chunk.content, position, &put_map_value(&1, field, text))}
        end)
      end

      alone = fn text ->
        update_chunk(envelope, &%{&1 | content: [put_map_value(block, field, text)], tool_call_chunks: []})
      end

      {{{:chunk, field, map_get(block, :index)}, stream_source(envelope)}, text, put, alone}
    end
  end

  defp chunk_content_slots(_envelope, _chunk), do: []

  defp chunk_args_slots(envelope, %AIChunk{tool_call_chunks: calls}) when is_list(calls) do
    for {%ToolCallChunk{args: args} = call, position} <- Enum.with_index(calls), is_binary(args) do
      put = fn envelope, text ->
        update_chunk(envelope, fn chunk ->
          %{chunk | tool_call_chunks: List.update_at(chunk.tool_call_chunks, position, &%{&1 | args: text})}
        end)
      end

      alone = fn text ->
        update_chunk(envelope, &%{&1 | content: empty_content(&1.content), tool_call_chunks: [%{call | args: text}]})
      end

      {args_lane(:chunk_args, call, envelope), args, put, alone}
    end
  end

  defp chunk_args_slots(_envelope, _chunk), do: []

  defp args_lane(_kind, %ToolCallChunk{index: nil}, _envelope), do: nil
  defp args_lane(kind, %ToolCallChunk{index: index}, envelope), do: {{kind, index}, stream_source(envelope)}

  defp protocol_slots(payload, source, put_payload) do
    case protocol_payload_text(payload) do
      text when is_binary(text) ->
        put = fn _event, text -> put_payload.(put_protocol_payload_text(payload, text)) end
        [{{:protocol, source}, text, put, &put.(nil, &1)}]

      _other ->
        []
    end
  end

  # Emits all but the last few graphemes of each lane's text and holds those
  # back, so a value split across chunks is redacted once the next chunk
  # arrives. `pending` keeps each lane's held-back text, and an event that
  # carries only that text, in the order the lanes started.
  defp redact_stream_slots(middleware, event, slots, pending) do
    Enum.reduce_while(slots, {{:ok, event}, pending}, fn {lane, text, put, alone}, {{:ok, event}, pending} ->
      case edit_text(held_text(pending, lane) <> text, middleware) do
        {:ok, edited} when is_nil(lane) ->
          {:cont, {{:ok, put.(event, edited)}, pending}}

        {:ok, edited} ->
          {emit, held} = split_stream_text(edited)
          pending = List.keystore(pending, lane, 0, {lane, %{text: held, event: alone.(held)}})
          {:cont, {{:ok, put.(event, emit)}, pending}}

        error ->
          {:halt, {error, pending}}
      end
    end)
  end

  defp held_text(pending, lane) do
    case List.keyfind(pending, lane, 0) do
      {^lane, %{text: text}} -> text
      nil -> ""
    end
  end

  defp redact_stream_value(middleware, %Envelope{event: %Events.Message{message: message} = event} = envelope, pending),
    do: redact_then_flush(message, middleware, pending, :all, &%{envelope | event: %{event | message: &1}})

  defp redact_stream_value(middleware, %Envelope{event: %Events.ToolStart{input: input} = event} = envelope, pending),
    do: redact_then_flush(input, middleware, pending, :none, &%{envelope | event: %{event | input: &1}})

  defp redact_stream_value(middleware, %Envelope{event: %Events.ToolDelta{delta: delta} = event} = envelope, pending),
    do: redact_then_flush(delta, middleware, pending, :none, &%{envelope | event: %{event | delta: &1}})

  defp redact_stream_value(
         middleware,
         %Envelope{event: %Events.ToolFinish{output: output, tool_call_id: id} = event} = envelope,
         pending
       ),
       do: redact_then_flush(output, middleware, pending, {:tool, id}, &%{envelope | event: %{event | output: &1}})

  defp redact_stream_value(
         middleware,
         %Envelope{event: %Events.ToolError{message: message, tool_call_id: id} = event} = envelope,
         pending
       ),
       do: redact_then_flush(message, middleware, pending, {:tool, id}, &%{envelope | event: %{event | message: &1}})

  defp redact_stream_value(middleware, %Envelope{event: %Events.GraphValue{value: value} = event} = envelope, pending),
    do: redact_then_flush(value, middleware, pending, :none, &%{envelope | event: %{event | value: &1}})

  defp redact_stream_value(_middleware, %Envelope{event: %Events.Done{}} = envelope, pending),
    do: flush(pending, {:source, stream_source(envelope)}, envelope)

  defp redact_stream_value(
         _middleware,
         %Envelope{event: %Events.Debug{payload: %{type: :model_call_failed}}} = envelope,
         pending
       ),
       do: flush(pending, {:source, stream_source(envelope)}, envelope)

  defp redact_stream_value(_middleware, %Envelope{event: %Events.Error{}} = envelope, pending),
    do: flush(pending, :all, envelope)

  defp redact_stream_value(_middleware, event, pending) do
    if protocol_message_finish?(event),
      do: flush(pending, :all, event),
      else: {{:ok, event}, pending}
  end

  defp redact_then_flush(value, middleware, pending, lanes, put) do
    case redact_value(value, middleware) do
      {:ok, value} -> flush(pending, lanes, put.(value))
      error -> {error, pending}
    end
  end

  # Emits the text the named lanes hold back, before `event`: a `Done` or a
  # failed model call ends its own model call's lanes (all of them when it
  # has no source details), a finished tool its output's lane, and a whole
  # `Message`, an `Error` or a protocol `message-finish` every lane.
  defp flush(pending, lanes, event) do
    {flushed, kept} = Enum.split_with(pending, fn {lane, _held} -> ends_lane?(lanes, lane) end)

    case for {_lane, %{text: text, event: held}} <- flushed, text != "", do: held do
      [] -> {{:ok, event}, kept}
      held -> {{:ok, held ++ [event]}, kept}
    end
  end

  defp ends_lane?(:all, _lane), do: true
  defp ends_lane?({:source, {nil, nil, []}}, _lane), do: true
  defp ends_lane?({:source, source}, {_kind, source}), do: true
  defp ends_lane?({:tool, id}, {{:tool_delta, id}, _source}), do: true
  defp ends_lane?(_lanes, _lane), do: false

  # What a stream shows of a value: every string of plain maps and lists, the
  # content of a message and the arguments of its tool calls, and the fields
  # of content blocks.
  defp redact_value(text, middleware) when is_binary(text), do: edit_text(text, middleware)
  defp redact_value(list, middleware) when is_list(list), do: edit_all(list, &redact_value(&1, middleware))

  defp redact_value(%Message{} = message, middleware) do
    with {:ok, content} <- redact_value(message.content, middleware),
         {:ok, calls} <- redact_value(message.tool_calls, middleware),
         do: {:ok, %{message | content: content, tool_calls: calls}}
  end

  defp redact_value(%module{args: args} = call, middleware) when module in [ToolCall, InvalidToolCall] do
    with {:ok, args} <- redact_value(args, middleware), do: {:ok, %{call | args: args}}
  end

  defp redact_value(%module{} = block, middleware) when module in @content_blocks do
    with {:ok, fields} <- redact_value(Map.from_struct(block), middleware), do: {:ok, struct(module, fields)}
  end

  # Any other struct, such as a date, is a value of its own.
  defp redact_value(%_{} = value, _middleware), do: {:ok, value}

  defp redact_value(%{} = map, middleware) do
    with {:ok, pairs} <- edit_all(Map.to_list(map), &redact_pair(&1, middleware)), do: {:ok, Map.new(pairs)}
  end

  defp redact_value(value, _middleware), do: {:ok, value}

  defp redact_pair({key, value}, middleware) do
    with {:ok, value} <- redact_value(value, middleware), do: {:ok, {key, value}}
  end

  defp edit_all(items, edit) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case edit.(item) do
        {:ok, edited} -> {:cont, {:ok, [edited | acc]}}
        {:error, %Error{}} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, edited} -> {:ok, Enum.reverse(edited)}
      error -> error
    end
  end

  defp update_event(%Envelope{event: event} = envelope, fun), do: %{envelope | event: fun.(event)}
  defp update_chunk(envelope, fun), do: update_event(envelope, &%{&1 | chunk: fun.(&1.chunk)})

  defp empty_content(content) when is_list(content), do: []
  defp empty_content(_content), do: ""

  defp stream_source(%Envelope{run_id: run_id, task_id: task_id, namespace: namespace}),
    do: {run_id, task_id, namespace || []}

  defp protocol_source(params, metadata) do
    run_id = if is_map(metadata), do: map_get(metadata, :run_id)
    {run_id, nil, map_get(params, :namespace) || []}
  end

  defp protocol_payload_text(payload) do
    with block when is_map(block) <- map_get(payload, :content_block),
         text when is_binary(text) <- map_get(block, :text) do
      text
    else
      _other -> nil
    end
  end

  defp put_protocol_payload_text(payload, text) do
    block = payload |> map_get(:content_block, %{}) |> put_map_value(:text, text)
    put_map_value(payload, :content_block, block)
  end

  defp protocol_message_finish?(%{"params" => %{"data" => {%{} = payload, _metadata}}}), do: message_finish?(payload)
  defp protocol_message_finish?(%{params: %{data: {%{} = payload, _metadata}}}), do: message_finish?(payload)
  defp protocol_message_finish?(_event), do: false

  defp message_finish?(payload), do: map_get(payload, :event) in ["message-finish", :message_finish]

  defp split_stream_text(text) do
    length = String.length(text)

    if length <= @stream_tail_graphemes do
      {"", text}
    else
      String.split_at(text, length - @stream_tail_graphemes)
    end
  end

  defp edit_text(text, %__MODULE__{} = middleware) do
    matches = Detector.detect(text, middleware)

    if matches == [] do
      {:ok, text}
    else
      case middleware.strategy do
        :block ->
          {:error, pii_error(matches)}

        :redact ->
          {:ok, replace_matches(text, matches, &redact(&1, middleware))}

        :mask ->
          {:ok, replace_matches(text, matches, &mask/1)}

        :hash ->
          {:ok, replace_matches(text, matches, &hash/1)}
      end
    end
  end

  defp replace_matches(text, matches, fun) do
    matches
    |> Enum.map(&Detector.normalize_match(&1, nil))
    |> Enum.reject(&is_nil/1)
    |> reject_overlaps()
    |> Enum.sort_by(& &1.start, :desc)
    |> Enum.reduce(text, fn match, acc ->
      binary_part(acc, 0, match.start) <>
        fun.(match) <> binary_part(acc, match.end, byte_size(acc) - match.end)
    end)
  end

  defp reject_overlaps(matches) do
    matches
    |> Enum.sort_by(&{&1.start, -&1.end})
    |> Enum.reduce([], fn match, kept ->
      case kept do
        [%{end: prev_end} | _] when match.start < prev_end -> kept
        _ -> [match | kept]
      end
    end)
  end

  defp redact(_match, %__MODULE__{replacement: replacement}) when is_binary(replacement),
    do: replacement

  defp redact(match, _middleware), do: "[REDACTED_#{String.upcase(match.type)}]"

  defp mask(%{type: "email", value: value}) do
    case String.split(value, "@", parts: 2) do
      [user, domain] ->
        case String.split(domain, ".") do
          [_single] -> user <> "@****"
          parts -> user <> "@****." <> List.last(parts)
        end

      _other ->
        "****"
    end
  end

  defp mask(%{type: "credit_card", value: value}) do
    digits = String.replace(value, ~r/\D/, "")
    suffix = String.slice(digits, -4, 4)

    cond do
      String.contains?(value, "-") -> "****-****-****-" <> suffix
      String.contains?(value, " ") -> "**** **** **** " <> suffix
      true -> "************" <> suffix
    end
  end

  defp mask(%{type: "ip", value: value}) do
    case String.split(value, ".") do
      [_, _, _, last] -> "*.*.*." <> last
      _other -> "****"
    end
  end

  defp mask(%{type: "mac_address", value: value}) do
    separator = if String.contains?(value, ":"), do: ":", else: "-"

    "**#{separator}**#{separator}**#{separator}**#{separator}**#{separator}" <>
      String.slice(value, -2, 2)
  end

  defp mask(%{type: "url"}), do: "[MASKED_URL]"

  defp mask(%{value: value}) when byte_size(value) <= 4, do: "****"

  defp mask(%{value: value}) do
    suffix = binary_part(value, byte_size(value) - 4, 4)
    "****" <> suffix
  end

  defp hash(%{type: type, value: value}) do
    digest =
      :crypto.hash(:sha256, value)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 8)

    "<#{type}_hash:#{digest}>"
  end

  defp pii_error([first | _] = matches) do
    Error.new(
      :pii_detected,
      "Detected #{length(matches)} instance(s) of #{first.type} in text content",
      %{pii_type: first.type, matches: matches}
    )
  end

  defp map_get(map, key, default \\ nil) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp put_map_value(map, key, value) when is_map(map) do
    string_key = Atom.to_string(key)

    cond do
      Map.has_key?(map, key) -> Map.put(map, key, value)
      Map.has_key?(map, string_key) -> Map.put(map, string_key, value)
      true -> Map.put(map, key, value)
    end
  end

  defp normalize_strategy!(strategy),
    do: Options.atom_enum!("strategy", strategy, @strategies)
end
