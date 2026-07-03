defmodule BeamWeaver.Agent.Middleware.PII do
  @moduledoc """
  Detects and edits common PII in agent message text.

  The middleware keeps BeamWeaver's native middleware shape while matching the
  LangChain PII semantics: each rule can target user input, model output, tool
  results, or any combination of those boundaries.
  """

  @behaviour BeamWeaver.Agent.Middleware

  alias BeamWeaver.Agent.Middleware.PII.Detector
  alias BeamWeaver.Agent.State
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Messages.AIChunk
  alias BeamWeaver.Graph.Overwrite
  alias BeamWeaver.Options
  alias BeamWeaver.Stream.Envelope
  alias BeamWeaver.Stream.Events

  @default_detectors [:email, :credit_card, :ip, :mac_address, :url]
  @strategies [:block, :redact, :mask, :hash]
  @stream_tail_graphemes 512

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
  def can_jump_to(_middleware, hook) when hook in [:before_model, :after_model], do: [:end]
  def can_jump_to(_middleware, _hook), do: []

  def before_model(
        %__MODULE__{apply_to_input: false, apply_to_tool_results: false},
        _state,
        _runtime
      ),
      do: nil

  def before_model(%__MODULE__{} = middleware, state, _runtime) do
    messages = State.messages(state)

    messages
    |> edit_before_model(middleware)
    |> format_update(messages)
  end

  def after_model(%__MODULE__{apply_to_output: false}, _state, _runtime), do: nil

  def after_model(%__MODULE__{} = middleware, state, _runtime) do
    messages = State.messages(state)

    messages
    |> edit_last_message(:assistant, middleware)
    |> format_update(messages)
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
  Applies a redaction strategy to previously detected PII matches.
  """
  def apply_strategy(content, [], _strategy), do: content

  def apply_strategy(content, matches, strategy) when is_binary(content) and is_list(matches) do
    case normalize_strategy!(strategy) do
      :redact -> replace_matches(content, matches, &redacted_placeholder/1)
      :mask -> replace_matches(content, matches, &mask/1)
      :hash -> replace_matches(content, matches, &hash/1)
      :block -> raise ArgumentError, "PII block strategy must be handled at middleware boundary"
    end
  end

  @doc """
  Returns a pre-projection stream transform that applies the middleware strategy
  to streamed text before message projection.
  """
  @spec stream_transform(t() | keyword()) :: (term() ->
                                                term() | [term()] | {:ok, term() | [term()]} | {:error, Error.t()})
  def stream_transform(%__MODULE__{} = middleware) do
    state_key = {__MODULE__, make_ref()}

    fn event -> redact_stream_event(middleware, state_key, event) end
  end

  def stream_transform(opts) when is_list(opts), do: opts |> new() |> stream_transform()

  defp edit_before_model(messages, middleware) do
    with {:ok, messages, changed?} <-
           maybe_edit_last_input(messages, middleware, middleware.apply_to_input),
         {:ok, messages, tool_changed?} <-
           maybe_edit_tool_results(messages, middleware, middleware.apply_to_tool_results) do
      {:ok, messages, changed? or tool_changed?}
    end
  end

  defp redact_stream_event(
         %__MODULE__{} = middleware,
         state_key,
         %Envelope{event: %Events.Token{text: text} = event} = envelope
       )
       when is_binary(text) do
    redact_stream_text(middleware, state_key, text, fn updated ->
      %{envelope | event: %{event | text: updated}}
    end)
  end

  defp redact_stream_event(
         %__MODULE__{} = middleware,
         state_key,
         %Envelope{event: %Events.MessageChunk{chunk: %AIChunk{content: content} = chunk} = event} =
           envelope
       )
       when is_binary(content) do
    redact_stream_text(middleware, state_key, content, fn updated ->
      %{envelope | event: %{event | chunk: %{chunk | content: updated}}}
    end)
  end

  defp redact_stream_event(
         %__MODULE__{} = middleware,
         state_key,
         %Envelope{event: %Events.Message{message: %Message{content: content} = message} = event} = envelope
       )
       when is_binary(content) do
    with {:ok, edited} <- edit_text(content, middleware) do
      event = %{envelope | event: %{event | message: %{message | content: edited}}}
      flush_stream_pending(state_key, event)
    end
  end

  defp redact_stream_event(
         %__MODULE__{} = middleware,
         state_key,
         %{"params" => %{"data" => {%{} = payload, metadata}} = params} = event
       ) do
    case protocol_payload_text(payload) do
      text when is_binary(text) ->
        redact_stream_text(middleware, state_key, text, fn updated ->
          payload = put_protocol_payload_text(payload, updated)
          %{event | "params" => %{params | "data" => {payload, metadata}}}
        end)

      _other ->
        maybe_flush_stream_pending(middleware, state_key, event, payload)
    end
  end

  defp redact_stream_event(
         %__MODULE__{} = middleware,
         state_key,
         %{params: %{data: {%{} = payload, metadata}} = params} = event
       ) do
    case protocol_payload_text(payload) do
      text when is_binary(text) ->
        redact_stream_text(middleware, state_key, text, fn updated ->
          payload = put_protocol_payload_text(payload, updated)
          %{event | params: %{params | data: {payload, metadata}}}
        end)

      _other ->
        maybe_flush_stream_pending(middleware, state_key, event, payload)
    end
  end

  defp redact_stream_event(_middleware, state_key, %Envelope{event: %Events.Done{}} = event),
    do: flush_stream_pending(state_key, event)

  defp redact_stream_event(_middleware, state_key, %Envelope{event: %Events.Error{}} = event),
    do: flush_stream_pending(state_key, event)

  defp redact_stream_event(_middleware, _state_key, event), do: {:ok, event}

  defp redact_stream_text(%__MODULE__{} = middleware, state_key, text, put_text) do
    combined = stream_pending_text(state_key) <> text

    with {:ok, edited} <- edit_text(combined, middleware) do
      {emit_text, pending_text} = split_stream_text(edited)
      pending_event = put_text.(pending_text)
      store_stream_pending(state_key, pending_text, pending_event)

      {:ok, put_text.(emit_text)}
    end
  end

  defp maybe_flush_stream_pending(_middleware, state_key, event, payload) do
    if protocol_terminal_event?(payload) do
      flush_stream_pending(state_key, event)
    else
      {:ok, event}
    end
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

  defp protocol_terminal_event?(payload) do
    map_get(payload, :event) in ["message-finish", :message_finish, :message_finish]
  end

  defp stream_pending_text(state_key) do
    state_key
    |> Process.get(%{})
    |> Map.get(:pending_text, "")
  end

  defp store_stream_pending(state_key, "", _pending_event), do: Process.delete(state_key)

  defp store_stream_pending(state_key, pending_text, pending_event) do
    Process.put(state_key, %{pending_text: pending_text, pending_event: pending_event})
  end

  defp flush_stream_pending(state_key, event) do
    case Process.get(state_key) do
      %{pending_text: pending_text, pending_event: pending_event} when pending_text != "" ->
        Process.delete(state_key)
        {:ok, [pending_event, event]}

      _other ->
        Process.delete(state_key)
        {:ok, event}
    end
  end

  defp split_stream_text(text) do
    length = String.length(text)

    if length <= @stream_tail_graphemes do
      {"", text}
    else
      String.split_at(text, length - @stream_tail_graphemes)
    end
  end

  defp maybe_edit_last_input(messages, _middleware, false), do: {:ok, messages, false}

  defp maybe_edit_last_input(messages, middleware, true),
    do: edit_last_message(messages, :user, middleware)

  defp maybe_edit_tool_results(messages, _middleware, false), do: {:ok, messages, false}

  defp maybe_edit_tool_results(messages, middleware, true) do
    case last_role_index(messages, :assistant) do
      nil ->
        {:ok, messages, false}

      last_ai_idx ->
        edit_messages_after(messages, last_ai_idx, middleware, false)
    end
  end

  defp edit_messages_after(messages, index, _middleware, changed?)
       when index >= length(messages) - 1,
       do: {:ok, messages, changed?}

  defp edit_messages_after(messages, index, middleware, changed?) do
    next_index = index + 1

    case Enum.at(messages, next_index) do
      %Message{role: :tool, content: content} = message when is_binary(content) ->
        case edit_text(content, middleware) do
          {:ok, ^content} ->
            edit_messages_after(messages, next_index, middleware, changed?)

          {:ok, edited} ->
            messages
            |> List.replace_at(next_index, %{message | content: edited})
            |> edit_messages_after(next_index, middleware, true)

          {:error, %Error{} = error} ->
            {:error, error}
        end

      _other ->
        edit_messages_after(messages, next_index, middleware, changed?)
    end
  end

  defp edit_last_message(messages, role, middleware) do
    case last_role_index(messages, role) do
      nil ->
        {:ok, messages, false}

      index ->
        with {:ok, message, changed?} <- edit_message(Enum.at(messages, index), middleware) do
          if changed? do
            {:ok, List.replace_at(messages, index, message), true}
          else
            {:ok, messages, false}
          end
        end
    end
  end

  defp edit_message(%Message{} = message, middleware) do
    with {:ok, message, content_changed?} <- edit_message_content(message, middleware),
         {:ok, message, tool_calls_changed?} <- edit_message_tool_calls(message, middleware) do
      {:ok, message, content_changed? or tool_calls_changed?}
    end
  end

  defp edit_message(message, _middleware), do: {:ok, message, false}

  defp edit_message_content(%Message{content: content} = message, middleware)
       when is_binary(content) and content != "" do
    case edit_text(content, middleware) do
      {:ok, ^content} -> {:ok, message, false}
      {:ok, edited} -> {:ok, %{message | content: edited}, true}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp edit_message_content(%Message{content: content} = message, middleware) when is_list(content) do
    with {:ok, content, changed?} <- edit_content_tool_calls(content, middleware) do
      {:ok, %{message | content: content}, changed?}
    end
  end

  defp edit_message_content(%Message{} = message, _middleware), do: {:ok, message, false}

  defp edit_message_tool_calls(%Message{tool_calls: calls} = message, middleware)
       when is_list(calls) and calls != [] do
    with {:ok, calls, changed?} <- edit_tool_call_list(calls, middleware) do
      {:ok, %{message | tool_calls: calls}, changed?}
    end
  end

  defp edit_message_tool_calls(%Message{} = message, _middleware), do: {:ok, message, false}

  defp format_update({:ok, _messages, false}, _original), do: nil
  defp format_update({:ok, messages, true}, _original), do: %{messages: Overwrite.new(messages)}
  defp format_update({:error, %Error{} = error}, _original), do: {:error, error}

  defp edit_content_tool_calls(content, middleware) do
    Enum.reduce_while(content, {:ok, [], false}, fn block, {:ok, acc, changed?} ->
      case edit_content_tool_call(block, middleware) do
        {:ok, edited, block_changed?} -> {:cont, {:ok, [edited | acc], changed? or block_changed?}}
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, edited, changed?} -> {:ok, Enum.reverse(edited), changed?}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp edit_content_tool_call(%{} = block, middleware) do
    if tool_call_block?(block) do
      edit_tool_call(block, middleware)
    else
      {:ok, block, false}
    end
  end

  defp edit_content_tool_call(block, _middleware), do: {:ok, block, false}

  defp edit_tool_call_list(calls, middleware) do
    Enum.reduce_while(calls, {:ok, [], false}, fn call, {:ok, acc, changed?} ->
      case edit_tool_call(call, middleware) do
        {:ok, edited, call_changed?} -> {:cont, {:ok, [edited | acc], changed? or call_changed?}}
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, edited, changed?} -> {:ok, Enum.reverse(edited), changed?}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp edit_tool_call(%{} = call, middleware) do
    call
    |> tool_argument_keys()
    |> Enum.reduce_while({:ok, call, false}, fn key, {:ok, acc, changed?} ->
      value = Map.fetch!(acc, key)

      case edit_tool_argument_value(value, middleware) do
        {:ok, ^value, false} -> {:cont, {:ok, acc, changed?}}
        {:ok, edited, _arg_changed?} -> {:cont, {:ok, Map.put(acc, key, edited), true}}
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp edit_tool_call(call, _middleware), do: {:ok, call, false}

  defp tool_argument_keys(call) do
    [:args, "args", :arguments, "arguments", :input, "input"]
    |> Enum.filter(&Map.has_key?(call, &1))
  end

  defp tool_call_block?(block) do
    map_get(block, :type) in [:tool_call, "tool_call", :tool_use, "tool_use"]
  end

  defp edit_tool_argument_value(value, middleware) when is_binary(value) do
    case edit_text(value, middleware) do
      {:ok, ^value} -> {:ok, value, false}
      {:ok, edited} -> {:ok, edited, true}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp edit_tool_argument_value(value, middleware) when is_list(value) do
    Enum.reduce_while(value, {:ok, [], false}, fn item, {:ok, acc, changed?} ->
      case edit_tool_argument_value(item, middleware) do
        {:ok, edited, item_changed?} -> {:cont, {:ok, [edited | acc], changed? or item_changed?}}
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, edited, changed?} -> {:ok, Enum.reverse(edited), changed?}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp edit_tool_argument_value(%{} = value, middleware) do
    Enum.reduce_while(value, {:ok, value, false}, fn {key, item}, {:ok, acc, changed?} ->
      case edit_tool_argument_value(item, middleware) do
        {:ok, ^item, false} -> {:cont, {:ok, acc, changed?}}
        {:ok, edited, _item_changed?} -> {:cont, {:ok, Map.put(acc, key, edited), true}}
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp edit_tool_argument_value(value, _middleware), do: {:ok, value, false}

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

  defp redact(match, _middleware), do: redacted_placeholder(match)

  defp redacted_placeholder(match), do: "[REDACTED_#{String.upcase(match.type)}]"

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

  defp last_role_index(messages, role) do
    messages
    |> Enum.with_index()
    |> Enum.reverse()
    |> Enum.find_value(fn
      {%Message{role: ^role}, index} -> index
      _other -> nil
    end)
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
