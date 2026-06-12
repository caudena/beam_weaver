defmodule BeamWeaver.Stream.MessageStream do
  @moduledoc """
  Native projection of a streamed assistant message.

  Python LangGraph exposes mutable `ChatModelStream` objects from its v3
  message transformer. BeamWeaver keeps the same observable information in an
  immutable struct that can be reduced, inspected, and passed through normal
  Elixir streams.
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
          done: boolean(),
          metadata: map()
        }

  @spec text(t()) :: String.t()
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
  Reduces LangGraph-style v3 message protocol events into BeamWeaver streams.

  The transformer is intentionally a pure immutable reducer. It accepts the
  event dictionaries produced by the upstream Python tests and by BeamWeaver's
  typed stream boundary, ignores legacy v1 chunks/tool messages/subgraph
  namespaces, and returns native `%BeamWeaver.Stream.MessageStream{}` structs.
  Async behavior is expressed through `BeamWeaver.Core.Async` rather than a
  separate async stream class.
  """

  alias BeamWeaver.Core.Async
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Stream.MessagesTransformer.Parser
  alias BeamWeaver.Stream.MessageStream

  defstruct by_run: %{},
            completed: [],
            open_order: [],
            ignored_runs: [],
            async?: false,
            pump: nil

  @type t :: %__MODULE__{
          by_run: %{optional(term()) => MessageStream.t()},
          completed: [MessageStream.t()],
          open_order: [term()],
          ignored_runs: [term()],
          async?: boolean(),
          pump: (-> boolean()) | nil
        }

  @spec new(keyword() | map()) :: t()
  def new(opts \\ []) do
    opts = if is_map(opts), do: Map.to_list(opts), else: opts
    %__MODULE__{async?: Keyword.get(opts, :async?, false), pump: Keyword.get(opts, :pump)}
  end

  @spec bind_pump(t(), (-> boolean())) :: t()
  def bind_pump(%__MODULE__{} = transformer, pump) when is_function(pump, 0),
    do: %{transformer | pump: pump}

  @spec process(t(), term()) :: {:ok, t(), [MessageStream.t()]} | {:pass, t()}
  def process(%__MODULE__{} = transformer, event) do
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

  @spec process_many(t() | [term()], [term()] | keyword(), keyword()) ::
          {:ok, t(), [MessageStream.t()]}
  def process_many(transformer_or_events, events_or_opts, opts \\ [])

  def process_many(%__MODULE__{} = transformer, events, _opts) when is_list(events) do
    Enum.reduce(events, {:ok, transformer, []}, fn event, {:ok, acc, emitted} ->
      case process(acc, event) do
        {:ok, next, new_streams} -> {:ok, next, emitted ++ new_streams}
        {:pass, next} -> {:ok, next, emitted}
      end
    end)
  end

  def process_many(events, opts, async_opts) when is_list(events) do
    process_many(new(opts), events, async_opts)
  end

  @spec async_process_many(t() | [term()], [term()] | keyword(), keyword()) :: Async.handle()
  def async_process_many(transformer_or_events, events_or_opts, opts \\ [])

  def async_process_many(%__MODULE__{} = transformer, events, opts) when is_list(events) do
    Async.run_call(opts, fn _call_opts -> process_many(transformer, events) end)
  end

  def async_process_many(events, opts, async_opts) when is_list(events) do
    async_process_many(new(opts), events, async_opts)
  end

  @spec streams(t()) :: [MessageStream.t()]
  def streams(%__MODULE__{} = transformer) do
    active =
      transformer.open_order
      |> Enum.flat_map(fn run_id ->
        case Map.fetch(transformer.by_run, run_id) do
          {:ok, stream} -> [stream]
          :error -> []
        end
      end)

    transformer.completed ++ active
  end

  @spec fail(t(), term()) :: t()
  def fail(%__MODULE__{} = transformer, error) do
    failed =
      transformer.open_order
      |> Enum.flat_map(fn run_id ->
        case Map.fetch(transformer.by_run, run_id) do
          {:ok, stream} -> [%{stream | error: error, done: true}]
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
        update_open_stream(transformer, metadata, &record_event(&1, payload))

      "content-block-delta" ->
        update_open_stream(transformer, metadata, fn stream ->
          stream
          |> record_event(payload)
          |> append_text_delta(text_from_content_block(map_get(payload, :content_block)))
        end)

      "content-block-finish" ->
        update_open_stream(transformer, metadata, fn stream ->
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
    run_id = run_id(metadata) || map_get(payload, :message_id)
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
    run_id = run_id(metadata)

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

  defp update_open_stream(transformer, metadata, fun) do
    run_id = run_id(metadata)

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
    do: %{stream | events: stream.events ++ [event]}

  defp append_text_delta(stream, nil), do: stream
  defp append_text_delta(stream, ""), do: stream
  defp append_text_delta(stream, text), do: %{stream | text_deltas: stream.text_deltas ++ [text]}

  defp complete_stream(%MessageStream{} = stream, reason) do
    message =
      Message.assistant(MessageStream.text(stream),
        id: stream.message_id,
        metadata: stream.metadata,
        response_metadata: if(is_nil(reason), do: %{}, else: %{finish_reason: reason})
      )

    %{stream | done: true, output: message}
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
  defp node_name(metadata), do: map_get(metadata, :node)

  defp assistant_role?(role) when role in [:assistant, :ai, "assistant", "ai", nil], do: true
  defp assistant_role?(_role), do: false

  defp append_unique(values, value) do
    if value in values, do: values, else: values ++ [value]
  end

  defp map_get(map, key, default \\ nil)

  defp map_get(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end
end
