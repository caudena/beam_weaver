defmodule BeamWeaver.StreamTest do
  use ExUnit.Case, async: true

  # Upstream references:
  # - langchain/libs/core/tests/unit_tests/runnables/test_runnable.py::test_stream
  # - langgraph/libs/langgraph/tests/test_pregel.py stream event mode coverage

  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Messages
  alias BeamWeaver.Stream
  alias BeamWeaver.Stream.Envelope
  alias BeamWeaver.Stream.Events

  test "envelopes normalize metadata and keep namespaces as lists" do
    envelope =
      Stream.envelope(%Events.Token{text: "hello"},
        run_id: "run-1",
        graph: "parent",
        node: "model",
        task_id: "task-1",
        step: 2,
        namespace: [:parent, :child],
        metadata: %{tags: [:stream]}
      )

    assert %Envelope{
             event: %Events.Token{text: "hello"},
             run_id: "run-1",
             graph: "parent",
             node: "model",
             task_id: "task-1",
             step: 2,
             namespace: [:parent, :child],
             metadata: %{tags: [:stream]},
             timestamp: timestamp
           } = envelope

    assert is_integer(timestamp)
  end

  test "formatting always returns typed envelopes" do
    envelope =
      Stream.envelope(
        %Events.ToolStart{tool_call_id: "call-1", tool_name: "search", input: %{"q" => "beam"}},
        namespace: ["tools"]
      )

    assert Stream.format(envelope, :events) == envelope
    assert Stream.format(envelope, :tools) == envelope
    assert Stream.format(envelope, [:tools, :updates]) == envelope
  end

  test "LangSmith formatter exposes typed event metadata" do
    envelope =
      Stream.envelope(%Events.GraphUpdate{update: %{"model" => %{answer: 42}}},
        run_id: "run-1",
        graph: "support",
        node: "model",
        task_id: "task-1",
        step: 3,
        namespace: ["support", "child"],
        metadata: %{tags: [:agent]}
      )

    assert %{
             event: "graph_update",
             data: %{update: %{"model" => %{answer: 42}}, metadata: %{}},
             run_id: "run-1",
             name: "model",
             tags: [:agent],
             namespace: ["support", "child"],
             graph: "support",
             step: 3,
             task_id: "task-1"
           } = Stream.to_langsmith_event(envelope)
  end

  test "event spec table preserves event names and stream modes" do
    assert Stream.event_mode(Stream.event(:graph_value, %{answer: 42})) == :values
    assert Stream.event_mode(Stream.event(:tool_start, tool_name: "search")) == :tools
    assert Stream.event_mode(Stream.event(:error, RuntimeError.exception("bad"))) == :debug

    assert %{event: "tool_start", data: %{tool_name: "search"}} =
             Stream.event(:tool_start, tool_name: "search")
             |> Stream.envelope()
             |> Stream.to_langsmith_event()
  end

  test "LangSmith event formatter promotes provider, usage, tool, retriever, and vectorstore metadata" do
    envelope =
      Stream.envelope(%Events.Message{message: Message.assistant("ok")},
        run_id: "run-2",
        node: "model",
        metadata: %{
          provider: :openai,
          model: "gpt-5.4",
          invocation_params: %{temperature: 0.1},
          token_usage: %{input_tokens: 4, output_tokens: 2},
          tool_calls: [%{id: "call-1"}],
          retriever: %{name: "docs"},
          vectorstore: %{adapter: :ets}
        }
      )

    assert %{
             model_provider: :openai,
             model_name: "gpt-5.4",
             invocation_params: %{temperature: 0.1},
             token_usage: %{input_tokens: 4, output_tokens: 2},
             tool_calls: [%{id: "call-1"}],
             retriever: %{name: "docs"},
             vectorstore: %{adapter: :ets}
           } = Stream.to_langsmith_event(envelope)
  end

  test "Finalize protocol reduces message chunks into final messages" do
    assert %Message{content: "hello"} =
             BeamWeaver.Stream.Finalize.finalize([
               Messages.ai_chunk("hel"),
               Messages.ai_chunk("lo")
             ])
  end

  test "Mux cancels a live producer when the consumer halts early" do
    # Upstream reference:
    # langchain/libs/core/tests/unit_tests/language_models/test_chat_model_v3_stream.py
    # - async stream close cancels the producer task.
    parent = self()

    stream =
      BeamWeaver.Stream.Mux.stream(
        [
          {:sink, :slow_model,
           fn sink ->
             Process.flag(:trap_exit, true)
             send(parent, :producer_started)
             assert :ok = BeamWeaver.Stream.Sink.emit(sink, %Events.Token{text: "first"})

             receive do
               {:beam_weaver_mux_cancel, _token} ->
                 send(parent, :producer_cancelled)
                 :ok

               {:EXIT, _from, :shutdown} ->
                 send(parent, :producer_cancelled)
                 :ok
             after
               5_000 ->
                 send(parent, :producer_not_cancelled)
                 :ok
             end
           end}
        ],
        max_buffer: 8,
        cancel_timeout: 100
      )

    assert %Envelope{event: %Events.Token{text: "first"}} =
             Enum.find(stream, &match?(%Envelope{event: %Events.Token{}}, &1))

    assert_received :producer_started
    assert_receive :producer_cancelled, 500
    refute_received :producer_not_cancelled
  end

  test "Mux backpressure policies emit deterministic debug events" do
    stream =
      BeamWeaver.Stream.Mux.stream(
        [
          {:sink, :fast_model,
           fn sink ->
             BeamWeaver.Stream.Sink.emit(sink, %Events.Token{text: "one"})
             BeamWeaver.Stream.Sink.emit(sink, %Events.Token{text: "two"})
             :ok
           end}
        ],
        max_buffer: 0,
        overflow: :drop_newest
      )
      |> Enum.take(3)

    assert Enum.any?(stream, fn
             %Envelope{
               event: %Events.Debug{payload: %{type: :backpressure_drop, dropped: :newest}}
             } ->
               true

             _event ->
               false
           end)
  end

  test "Mux heartbeats are opt-in event-mode lifecycle events" do
    stream =
      BeamWeaver.Stream.Mux.stream(
        [
          {:sink, :quiet,
           fn _sink ->
             Process.sleep(80)
             :ok
           end}
        ],
        heartbeat: [interval_ms: 10, payload: %{source: :test}],
        timeout: 10
      )

    assert %Envelope{event: %Events.Debug{payload: %{type: :heartbeat, source: :test}}} =
             Enum.find(stream, fn
               %Envelope{event: %Events.Debug{payload: %{type: :heartbeat}}} -> true
               _event -> false
             end)
  end
end
