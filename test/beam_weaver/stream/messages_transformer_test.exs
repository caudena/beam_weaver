defmodule BeamWeaver.Stream.MessagesTransformerTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.Async
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Messages
  alias BeamWeaver.Stream.Envelope
  alias BeamWeaver.Stream.Events
  alias BeamWeaver.Stream.MessagesTransformer
  alias BeamWeaver.Stream.MessageStream

  test "message-start creates an inspectable native message stream" do
    t = MessagesTransformer.new()

    assert {:ok, t, [%MessageStream{message_id: "run-1", node: "llm", done: false}]} =
             MessagesTransformer.process(
               t,
               proto(%{"event" => "message-start", "role" => "ai", "message_id" => "run-1"})
             )

    assert [%MessageStream{message_id: "run-1"}] = MessagesTransformer.streams(t)
  end

  test "full protocol lifecycle accumulates text and finalizes output" do
    assert {:ok, t, _emitted} =
             MessagesTransformer.process_many(MessagesTransformer.new(), lifecycle("hello world"))

    assert [%MessageStream{done: true} = stream] = MessagesTransformer.streams(t)
    assert MessageStream.text(stream) == "hello world"

    assert %Message{role: :assistant, content: "hello world", id: "run-1"} =
             MessageStream.output!(stream)

    assert Enum.map(stream.events, &event_name/1) == [
             "message-start",
             "content-block-start",
             "content-block-delta",
             "content-block-delta",
             "content-block-finish",
             "message-finish"
           ]
  end

  test "message-finish cleans active routing while preserving completed streams" do
    assert {:ok, t, _emitted} =
             MessagesTransformer.process_many(MessagesTransformer.new(), lifecycle("done"))

    assert t.by_run == %{}
    assert t.open_order == []
    assert [%MessageStream{message_id: "run-1"}] = t.completed
  end

  test "orphan deltas, tool-role runs, subgraph namespaces, and v1 chunks are ignored" do
    t = MessagesTransformer.new()

    assert {:ok, t, []} =
             MessagesTransformer.process(
               t,
               proto(
                 %{
                   "event" => "content-block-delta",
                   "index" => 0,
                   "content_block" => %{"type" => "text", "text" => "orphan"}
                 },
                 run_id: "unknown"
               )
             )

    assert {:ok, t, []} =
             MessagesTransformer.process(
               t,
               proto(%{"event" => "message-start", "role" => "tool", "message_id" => "tool-run"},
                 run_id: "tool-run"
               )
             )

    assert {:ok, t, []} =
             MessagesTransformer.process(
               t,
               proto(%{"event" => "message-start", "message_id" => "nested"},
                 namespace: ["subgraph"],
                 run_id: "nested"
               )
             )

    assert {:ok, _t, []} =
             MessagesTransformer.process(
               t,
               proto(Messages.ai_chunk("legacy"), run_id: "legacy")
             )
  end

  test "concurrent protocol streams stay routed by run_id" do
    events =
      lifecycle("aaaa", run_id: "run-a", message_id: "run-a")
      |> Enum.zip(lifecycle("bbbb", run_id: "run-b", message_id: "run-b"))
      |> Enum.flat_map(fn {a, b} -> [a, b] end)

    assert {:ok, t, _emitted} =
             MessagesTransformer.process_many(MessagesTransformer.new(), events)

    by_id =
      t
      |> MessagesTransformer.streams()
      |> Map.new(fn stream -> {stream.message_id, MessageStream.text(stream)} end)

    assert by_id == %{"run-a" => "aaaa", "run-b" => "bbbb"}
  end

  test "whole assistant messages become completed streams and tool messages are skipped" do
    assert {:ok, t, [%MessageStream{} = stream]} =
             MessagesTransformer.process(
               MessagesTransformer.new(),
               whole_message(Message.assistant("the full answer", id: "msg-10"), node: "node")
             )

    assert stream.done
    assert stream.node == "node"
    assert MessageStream.text(stream) == "the full answer"

    assert Enum.map(stream.events, &event_name/1) == [
             "message-start",
             "content-block-start",
             "content-block-delta",
             "content-block-finish",
             "message-finish"
           ]

    assert {:ok, _t, []} =
             MessagesTransformer.process(
               t,
               whole_message(Message.tool("[]", tool_call_id: "call-1"), node: "tools")
             )
  end

  test "non-message events pass through for other stream modes" do
    assert {:pass, _t} =
             MessagesTransformer.process(MessagesTransformer.new(), %{
               "type" => "event",
               "method" => "values",
               "params" => %{"data" => %{"x" => 1}}
             })
  end

  test "fail and finalize clear active routing using immutable state" do
    assert {:ok, t, _emitted} =
             MessagesTransformer.process(
               MessagesTransformer.new(),
               proto(%{"event" => "message-start", "message_id" => "run-1"})
             )

    error = RuntimeError.exception("graph died")
    failed = MessagesTransformer.fail(t, error)
    assert failed.by_run == %{}
    assert [%MessageStream{error: ^error, done: true}] = failed.completed

    assert {:ok, active, _emitted} =
             MessagesTransformer.process(
               MessagesTransformer.new(),
               proto(%{"event" => "message-start", "message_id" => "run-1"})
             )

    assert MessagesTransformer.finalize(active).by_run == %{}
  end

  test "Task-backed async processing covers async-mode projection without a Python async class" do
    task = MessagesTransformer.async_process_many(lifecycle("async stream"), async?: true)
    assert {:ok, t, _emitted} = Async.await(task)
    assert [%MessageStream{} = stream] = MessagesTransformer.streams(t)
    assert MessageStream.text(stream) == "async stream"
    assert MessageStream.output!(stream).content == "async stream"
  end

  test "typed BeamWeaver message envelopes can be projected as whole messages" do
    envelope = %Envelope{
      event: %Events.Message{
        message: Message.assistant("typed", id: "msg-typed"),
        metadata: %{node: "model", run_id: "run-typed"}
      },
      node: "model",
      run_id: "run-typed"
    }

    assert {:ok, t, [%MessageStream{node: "model"}]} =
             MessagesTransformer.process(MessagesTransformer.new(), envelope)

    assert [%MessageStream{message_id: "msg-typed"}] = MessagesTransformer.streams(t)
  end

  test "whole-message fallback is deduped while a protocol stream is active" do
    assert {:ok, t, [_stream]} =
             MessagesTransformer.process(
               MessagesTransformer.new(),
               proto(%{"event" => "message-start", "message_id" => "stream-msg-1"},
                 run_id: "run-1"
               )
             )

    assert {:ok, t, []} =
             MessagesTransformer.process(
               t,
               whole_message(Message.assistant("hello", id: "final-msg-1"), run_id: "run-1")
             )

    assert [%MessageStream{message_id: "stream-msg-1"}] = MessagesTransformer.streams(t)
  end

  test "pump binding is retained as an explicit native callback" do
    transformer = MessagesTransformer.bind_pump(MessagesTransformer.new(), fn -> false end)
    assert is_function(transformer.pump, 0)
    refute transformer.pump.()
  end

  defp lifecycle(text, opts \\ []) do
    run_id = Keyword.get(opts, :run_id, "run-1")
    message_id = Keyword.get(opts, :message_id, run_id)
    split = div(String.length(text), 2)
    {first, second} = String.split_at(text, split)

    [
      proto(%{"event" => "message-start", "role" => "ai", "message_id" => message_id},
        run_id: run_id
      ),
      proto(
        %{
          "event" => "content-block-start",
          "index" => 0,
          "content_block" => %{"type" => "text", "text" => ""}
        },
        run_id: run_id
      ),
      proto(
        %{
          "event" => "content-block-delta",
          "index" => 0,
          "content_block" => %{"type" => "text", "text" => first}
        },
        run_id: run_id
      ),
      proto(
        %{
          "event" => "content-block-delta",
          "index" => 0,
          "content_block" => %{"type" => "text", "text" => second}
        },
        run_id: run_id
      ),
      proto(
        %{
          "event" => "content-block-finish",
          "index" => 0,
          "content_block" => %{"type" => "text", "text" => text}
        },
        run_id: run_id
      ),
      proto(%{"event" => "message-finish", "reason" => "stop"}, run_id: run_id)
    ]
  end

  defp proto(payload, opts \\ []) do
    run_id = Keyword.get(opts, :run_id, "run-1")
    node = Keyword.get(opts, :node, "llm")
    namespace = Keyword.get(opts, :namespace, [])

    %{
      "type" => "event",
      "method" => "messages",
      "params" => %{
        "namespace" => namespace,
        "timestamp" => 1,
        "data" => {payload, %{"node" => node, "run_id" => run_id}}
      }
    }
  end

  defp whole_message(%Message{} = message, opts) do
    %{
      "type" => "event",
      "method" => "messages",
      "params" => %{
        "namespace" => Keyword.get(opts, :namespace, []),
        "timestamp" => 1,
        "data" =>
          {message,
           %{
             "node" => Keyword.get(opts, :node, "node"),
             "run_id" => Keyword.get(opts, :run_id, message.id)
           }}
      }
    }
  end

  defp event_name(%{"event" => event}), do: event
  defp event_name(%{event: event}), do: event
end
