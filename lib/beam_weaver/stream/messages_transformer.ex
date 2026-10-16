defmodule BeamWeaver.Stream.MessageStream do
  @moduledoc """
  Projection of one streamed assistant message.

  An immutable struct with the message's protocol events, its text deltas (see
  `text/1`) and, once done, the final message (see `output/1`). It can be
  reduced, inspected, and passed through normal Elixir streams.
  """

  alias BeamWeaver.Core.Message

  defstruct [
    :message_id,
    :run_id,
    :node,
    :role,
    :output,
    :error,
    events: [],
    text_deltas: [],
    events_reversed?: false,
    text_deltas_reversed?: false,
    done: false,
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          message_id: String.t() | nil,
          run_id: String.t() | nil,
          node: term(),
          role: atom() | String.t() | nil,
          output: Message.t() | nil,
          error: term(),
          events: [map()],
          text_deltas: [String.t()],
          events_reversed?: boolean(),
          text_deltas_reversed?: boolean(),
          done: boolean(),
          metadata: map()
        }

  @spec text(t()) :: String.t()
  def text(%__MODULE__{text_deltas: deltas, text_deltas_reversed?: true}),
    do: deltas |> Enum.reverse() |> Enum.join("")

  def text(%__MODULE__{text_deltas: deltas}), do: Enum.join(deltas, "")

  @spec output(t()) :: {:ok, Message.t()} | {:error, term()} | nil
  def output(%__MODULE__{error: error}) when not is_nil(error), do: {:error, error}
  def output(%__MODULE__{output: %Message{} = message}), do: {:ok, message}

  def output(%__MODULE__{} = stream),
    do: {:ok, Message.assistant(text(stream), id: stream.message_id)}

  @spec output!(t()) :: Message.t()
  def output!(%__MODULE__{} = stream) do
    case output(stream) do
      {:ok, message} -> message
      {:error, error} -> raise RuntimeError, message: inspect(error)
    end
  end
end

defmodule BeamWeaver.Stream.MessagesTransformer do
  @moduledoc """
  Reduces message protocol events into `BeamWeaver.Stream.MessageStream` structs.

  The transformer is intentionally a pure immutable reducer. It accepts typed
  stream envelopes and `"messages"` protocol event maps, whose payloads follow
  the `message-start`, `content-block-start`/`-delta`/`-finish` and
  `message-finish` lifecycle. Bare chunk payloads, tool messages and events from
  subgraph namespaces are ignored.
  """

  alias BeamWeaver.Core.Message
  alias BeamWeaver.Stream.MessagesTransformer.Parser
  alias BeamWeaver.Stream.MessageStream

  defstruct by_run: %{},
            completed: [],
            open_order: [],
            ignored_runs: [],
            pump: nil,
            pre_projection: []

  @type t :: %__MODULE__{
          by_run: %{optional(term()) => MessageStream.t()},
          completed: [MessageStream.t()],
          open_order: [term()],
          ignored_runs: [term()],
          pump: (-> boolean()) | nil,
          pre_projection: [(term() -> term()) | {(term(), term() -> {term(), term()}), term()}]
        }

  @spec new(keyword() | map()) :: t()
  def new(opts \\ []) do
    opts = if is_map(opts), do: Map.to_list(opts), else: opts

    %__MODULE__{
      pump: Keyword.get(opts, :pump),
      pre_projection: normalize_pre_projection(Keyword.get(opts, :pre_projection, []))
    }
  end

  @spec bind_pump(t(), (-> boolean())) :: t()
  def bind_pump(%__MODULE__{} = transformer, pump) when is_function(pump, 0),
    do: %{transformer | pump: pump}

  @spec process(t(), term()) :: {:ok, t(), [MessageStream.t()]} | {:pass, t()}
  def process(%__MODULE__{} = transformer, event) do
    {result, transformer} = apply_pre_projection(transformer, event)

    case result do
      {:ok, events} when is_list(events) ->
        process_projected_events(transformer, events)

      {:ok, event} ->
        do_process(transformer, event)

      :drop ->
        {:ok, transformer, []}

      {:error, error} ->
        {:ok, fail(transformer, error), []}
    end
  end

  defp do_process(%__MODULE__{} = transformer, event) do
    case Parser.parse(event) do
      :pass ->
        {:pass, transformer}

      :ignore ->
        {:ok, transformer, []}

      {:protocol, payload, metadata} ->
        process_protocol(transformer, payload, metadata)

      {:whole_message, %Message{} = message, metadata} ->
        process_whole_message(transformer, message, metadata)
    end
  end

  defp process_projected_events(transformer, events) do
    Enum.reduce(events, {:ok, transformer, []}, fn event, {:ok, acc, emitted} ->
      case do_process(acc, event) do
        {:ok, next, streams} -> {:ok, next, prepend_all(emitted, streams)}
        {:pass, next} -> {:ok, next, emitted}
      end
    end)
    |> then(fn {:ok, next, emitted} -> {:ok, next, Enum.reverse(emitted)} end)
  end

  defp apply_pre_projection(%__MODULE__{pre_projection: []} = transformer, event),
    do: {{:ok, event}, transformer}

  defp apply_pre_projection(%__MODULE__{pre_projection: transforms} = transformer, event) do
    {result, transforms} = run_transforms(transforms, [event], [])
    {result, %{transformer | pre_projection: transforms}}
  end

  # Feeds each transform the events the previous one emitted; once a transform
  # drops everything or fails, the rest are skipped.
  defp run_transforms([], [single], done), do: {{:ok, single}, Enum.reverse(done)}
  defp run_transforms([], events, done), do: {{:ok, events}, Enum.reverse(done)}

  defp run_transforms([transform | rest], events, done) do
    case apply_pre_projection_transform(transform, events) do
      {{:ok, []}, transform} -> {:drop, Enum.reverse(done, [transform | rest])}
      {{:ok, events}, transform} -> run_transforms(rest, events, [transform | done])
      {error, transform} -> {error, Enum.reverse(done, [transform | rest])}
    end
  end

  defp apply_pre_projection_transform(transform, events) do
    Enum.reduce_while(events, {{:ok, []}, transform}, fn event, {{:ok, acc}, transform} ->
      {result, transform} = call_transform(transform, event)

      case normalize_pre_projection_result(result) do
        {:ok, next_events} -> {:cont, {{:ok, prepend_all(acc, next_events)}, transform}}
        :drop -> {:cont, {{:ok, acc}, transform}}
        {:error, error} -> {:halt, {{:error, error}, transform}}
      end
    end)
    |> case do
      {{:ok, next_events}, transform} -> {{:ok, Enum.reverse(next_events)}, transform}
      other -> other
    end
  end

  defp call_transform(fun, event) when is_function(fun, 1), do: {fun.(event), fun}

  defp call_transform({fun, state}, event) do
    {result, state} = fun.(event, state)
    {result, {fun, state}}
  end

  defp normalize_pre_projection_result({:ok, events}) when is_list(events), do: {:ok, events}
  defp normalize_pre_projection_result({:ok, event}), do: {:ok, [event]}
  defp normalize_pre_projection_result({:drop, _reason}), do: :drop
  defp normalize_pre_projection_result(:drop), do: :drop
  defp normalize_pre_projection_result({:error, error}), do: {:error, error}
  defp normalize_pre_projection_result(event), do: {:ok, [event]}

  @spec process_many(t(), [term()]) :: {:ok, t(), [MessageStream.t()]}
  def process_many(%__MODULE__{} = transformer, events) when is_list(events) do
    Enum.reduce(events, {:ok, transformer, []}, fn event, {:ok, acc, emitted} ->
      case process(acc, event) do
        {:ok, next, new_streams} -> {:ok, next, prepend_all(emitted, new_streams)}
        {:pass, next} -> {:ok, next, emitted}
      end
    end)
    |> then(fn {:ok, next, emitted} -> {:ok, next, Enum.reverse(emitted)} end)
  end

  @spec streams(t()) :: [MessageStream.t()]
  def streams(%__MODULE__{} = transformer) do
    active =
      transformer.open_order
      |> Enum.flat_map(fn run_id ->
        case Map.fetch(transformer.by_run, run_id) do
          {:ok, stream} -> [normalize_stream(stream)]
          :error -> []
        end
      end)

    Enum.map(transformer.completed, &normalize_stream/1) ++ active
  end

  @spec fail(t(), term()) :: t()
  def fail(%__MODULE__{} = transformer, error) do
    failed =
      transformer.open_order
      |> Enum.flat_map(fn run_id ->
        case Map.fetch(transformer.by_run, run_id) do
          {:ok, stream} -> [%{normalize_stream(stream) | error: error, done: true}]
          :error -> []
        end
      end)

    %{transformer | by_run: %{}, open_order: [], completed: transformer.completed ++ failed}
  end

  @spec finalize(t()) :: t()
  def finalize(%__MODULE__{} = transformer), do: %{transformer | by_run: %{}, open_order: []}

  defp process_protocol(transformer, payload, metadata) when is_map(payload) do
    case event_name(payload) do
      "message-start" ->
        start_message(transformer, payload, metadata)

      "message-finish" ->
        finish_message(transformer, payload, metadata)

      "content-block-start" ->
        update_open_stream(transformer, payload, metadata, &record_event(&1, payload))

      "content-block-delta" ->
        update_open_stream(transformer, payload, metadata, fn stream ->
          stream
          |> record_event(payload)
          |> append_text_delta(text_from_content_block(map_get(payload, :content_block)))
        end)

      "content-block-finish" ->
        update_open_stream(transformer, payload, metadata, fn stream ->
          stream =
            record_event(stream, payload)

          if MessageStream.text(stream) == "" do
            append_text_delta(stream, text_from_content_block(map_get(payload, :content_block)))
          else
            stream
          end
        end)

      _other ->
        {:ok, transformer, []}
    end
  end

  defp start_message(transformer, payload, metadata) do
    run_id = event_run_id(metadata, payload)
    role = map_get(payload, :role) || :assistant

    if assistant_role?(role) and not is_nil(run_id) do
      stream = %MessageStream{
        message_id: map_get(payload, :message_id) || run_id,
        run_id: run_id,
        node: node_name(metadata),
        role: role,
        events: [payload],
        metadata: metadata
      }

      transformer = %{
        transformer
        | by_run: Map.put(transformer.by_run, run_id, stream),
          open_order: append_unique(transformer.open_order, run_id)
      }

      {:ok, transformer, [stream]}
    else
      ignored =
        if is_nil(run_id),
          do: transformer.ignored_runs,
          else: append_unique(transformer.ignored_runs, run_id)

      {:ok, %{transformer | ignored_runs: ignored}, []}
    end
  end

  defp finish_message(transformer, payload, metadata) do
    run_id = open_run_id(transformer, metadata, payload)

    case Map.fetch(transformer.by_run, run_id) do
      {:ok, stream} ->
        stream =
          stream
          |> record_event(payload)
          |> complete_stream(map_get(payload, :reason))

        transformer = %{
          transformer
          | by_run: Map.delete(transformer.by_run, run_id),
            open_order: List.delete(transformer.open_order, run_id),
            completed: transformer.completed ++ [stream],
            ignored_runs: List.delete(transformer.ignored_runs, run_id)
        }

        {:ok, transformer, []}

      :error ->
        {:ok, %{transformer | ignored_runs: List.delete(transformer.ignored_runs, run_id)}, []}
    end
  end

  defp update_open_stream(transformer, payload, metadata, fun) do
    run_id = open_run_id(transformer, metadata, payload)

    case Map.fetch(transformer.by_run, run_id) do
      {:ok, stream} ->
        {:ok, %{transformer | by_run: Map.put(transformer.by_run, run_id, fun.(stream))}, []}

      :error ->
        {:ok, transformer, []}
    end
  end

  defp process_whole_message(transformer, %Message{role: :tool}, _metadata),
    do: {:ok, transformer, []}

  defp process_whole_message(transformer, %Message{role: :assistant} = message, metadata) do
    if active_run?(transformer, run_id(metadata)) do
      {:ok, transformer, []}
    else
      complete_whole_message(transformer, message, metadata)
    end
  end

  defp process_whole_message(transformer, _message, _metadata), do: {:ok, transformer, []}

  defp complete_whole_message(transformer, %Message{} = message, metadata) do
    text = Message.text(message)
    message_id = message.id || run_id(metadata)

    stream = %MessageStream{
      message_id: message_id,
      run_id: run_id(metadata) || message_id,
      node: node_name(metadata),
      role: :assistant,
      events: lifecycle_events(message_id, text),
      text_deltas: [text],
      done: true,
      output: message,
      metadata: metadata
    }

    {:ok, %{transformer | completed: transformer.completed ++ [stream]}, [stream]}
  end

  defp active_run?(_transformer, nil), do: false

  defp active_run?(%__MODULE__{} = transformer, run_id),
    do: Map.has_key?(transformer.by_run, run_id)

  defp record_event(%MessageStream{} = stream, event),
    do: %{stream | events: [event | stream.events], events_reversed?: true}

  defp append_text_delta(stream, nil), do: stream
  defp append_text_delta(stream, ""), do: stream

  defp append_text_delta(stream, text),
    do: %{stream | text_deltas: [text | stream.text_deltas], text_deltas_reversed?: true}

  defp complete_stream(%MessageStream{} = stream, reason) do
    text = MessageStream.text(stream)

    message =
      Message.assistant(text,
        id: stream.message_id,
        metadata: stream.metadata,
        response_metadata: if(is_nil(reason), do: %{}, else: %{finish_reason: reason})
      )

    %{normalize_stream(stream) | done: true, output: message}
  end

  defp lifecycle_events(message_id, text) do
    [
      %{event: "message-start", role: "ai", message_id: message_id},
      %{event: "content-block-start", index: 0, content_block: %{type: "text", text: ""}},
      %{event: "content-block-delta", index: 0, content_block: %{type: "text", text: text}},
      %{event: "content-block-finish", index: 0, content_block: %{type: "text", text: text}},
      %{event: "message-finish", reason: "stop"}
    ]
  end

  defp event_name(payload), do: map_get(payload, :event)

  defp text_from_content_block(nil), do: nil
  defp text_from_content_block(block) when is_map(block), do: map_get(block, :text)
  defp text_from_content_block(_block), do: nil

  defp run_id(metadata), do: map_get(metadata, :run_id) || map_get(metadata, :message_id)

  defp event_run_id(metadata, payload) do
    run_id(metadata) || map_get(payload, :run_id) || map_get(payload, :message_id)
  end

  defp open_run_id(%__MODULE__{} = transformer, metadata, payload) do
    case event_run_id(metadata, payload) do
      nil ->
        single_open_run_id(transformer)

      run_id ->
        cond do
          Map.has_key?(transformer.by_run, run_id) -> run_id
          message_run_id = run_id_for_message_id(transformer, run_id) -> message_run_id
          true -> run_id
        end
    end
  end

  defp run_id_for_message_id(%__MODULE__{by_run: by_run}, message_id) do
    Enum.find_value(by_run, fn
      {run_id, %MessageStream{message_id: ^message_id}} -> run_id
      _other -> nil
    end)
  end

  defp single_open_run_id(%__MODULE__{open_order: [run_id]}), do: run_id
  defp single_open_run_id(_transformer), do: nil

  defp node_name(metadata), do: map_get(metadata, :node)

  defp assistant_role?(role) when role in [:assistant, :ai, "assistant", "ai", nil], do: true
  defp assistant_role?(_role), do: false

  defp normalize_stream(%MessageStream{} = stream) do
    %{
      stream
      | events: normalize_order(stream.events, stream.events_reversed?),
        text_deltas: normalize_order(stream.text_deltas, stream.text_deltas_reversed?),
        events_reversed?: false,
        text_deltas_reversed?: false
    }
  end

  defp normalize_order(values, true), do: Enum.reverse(values)
  defp normalize_order(values, _false), do: values

  defp prepend_all(acc, values), do: Enum.reduce(values, acc, fn value, acc -> [value | acc] end)

  defp append_unique(values, value) do
    if value in values, do: values, else: values ++ [value]
  end

  defp normalize_pre_projection(nil), do: []
  defp normalize_pre_projection(funs) when is_list(funs), do: Enum.map(funs, &validate_pre_projection!/1)
  defp normalize_pre_projection(transform), do: [validate_pre_projection!(transform)]

  defp validate_pre_projection!(fun) when is_function(fun, 1), do: fun
  defp validate_pre_projection!({fun, _state} = transform) when is_function(fun, 2), do: transform

  defp validate_pre_projection!(other) do
    raise ArgumentError,
          "pre_projection transforms must be unary functions or {fun/2, state} pairs, got #{inspect(other)}"
  end

  defp map_get(map, key, default \\ nil)

  defp map_get(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end
end
