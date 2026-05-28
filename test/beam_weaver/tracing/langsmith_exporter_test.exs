defmodule BeamWeaver.Tracing.LangSmithExporterTest do
  use ExUnit.Case, async: false

  alias BeamWeaver.Core.ChatModel
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Graph
  alias BeamWeaver.Graph.Compiled
  alias BeamWeaver.Models.FakeChatModel
  alias BeamWeaver.Tracing
  alias BeamWeaver.Tracing.Exporters.LangSmith
  alias BeamWeaver.Tracing.Exporters.LangSmith.Queue
  alias BeamWeaver.Tracing.Exporters.LangSmith.TelemetrySubscriber
  alias BeamWeaver.Tracing.Run

  @uuid_regex ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/

  test "translates BeamWeaver runs into LangSmith-compatible payloads" do
    run =
      Run.new("agent",
        id: "run_1",
        trace_id: "trace_1",
        kind: :graph,
        inputs: %{question: "hi"},
        metadata: %{thread_id: "t1"},
        started_at: ~U[2026-05-21 00:00:00Z]
      )

    run = %{run | status: :ok, ended_at: ~U[2026-05-21 00:00:01Z], outputs: %{answer: "hello"}}

    payload = LangSmith.to_payload(:ok, run, "beam-weaver")

    assert %{
             id: id,
             trace_id: trace_id,
             parent_run_id: nil,
             dotted_order: dotted_order,
             name: "agent",
             run_type: "chain",
             start_time: "2026-05-21T00:00:00Z",
             end_time: "2026-05-21T00:00:01Z",
             status: "success",
             inputs: %{question: "hi"},
             outputs: %{answer: "hello"},
             error: nil,
             extra: %{
               metadata: %{
                 beam_weaver_run_id: "run_1",
                 beam_weaver_trace_id: "trace_1",
                 thread_id: "t1"
               },
               usage: %{},
               beam_weaver_kind: "graph"
             },
             tags: [],
             session_name: "beam-weaver"
           } = payload

    assert id =~ @uuid_regex
    assert trace_id =~ @uuid_regex
    assert dotted_order == "20260521T000000000000Z#{id}"
  end

  test "payload maps nested run and provider metadata without losing usage" do
    parent_id = "019e5c4d-6980-7000-8000-000000000001"
    parent_dotted_order = "20260520T235959000000Z#{parent_id}"

    run =
      Run.new("model-call",
        id: "child_1",
        trace_id: "trace_nested",
        parent_id: parent_id,
        kind: :model,
        inputs: %{messages: ["hi"]},
        metadata: %{
          parent_dotted_order: parent_dotted_order,
          invocation_params: %{temperature: 0.2},
          provider: :openai,
          model: "gpt-test",
          retriever: %{name: "docs"},
          vector_store: %{name: "pgvector"}
        },
        usage: %{input_tokens: 3, output_tokens: 4},
        started_at: ~U[2026-05-21 00:00:00Z]
      )

    payload = LangSmith.to_payload(:started, run, "beam-weaver")

    assert payload.id =~ @uuid_regex
    assert payload.trace_id =~ @uuid_regex
    assert payload.parent_run_id == parent_id
    assert payload.dotted_order == "#{parent_dotted_order}.20260521T000000000000Z#{payload.id}"
    assert payload.run_type == "llm"
    assert payload.status == "pending"
    assert payload.extra.metadata.beam_weaver_run_id == "child_1"
    assert payload.extra.metadata.beam_weaver_trace_id == "trace_nested"
    assert payload.extra.metadata.usage_metadata == %{input_tokens: 3, output_tokens: 4}
    assert payload.extra.usage == %{input_tokens: 3, output_tokens: 4}
    assert payload.extra.invocation_params == %{temperature: 0.2}
    assert payload.extra.model_provider == "openai"
    assert payload.extra.model_name == "gpt-test"
    assert payload.extra.retriever == %{name: "docs"}
    assert payload.extra.vectorstore == %{name: "pgvector"}
  end

  test "tool payloads synthesize Python-compatible fields only at export" do
    run =
      Run.new("search_docs",
        id: "tool_run_1",
        trace_id: "trace_tool",
        kind: :tool,
        inputs: %{"query" => "cats"},
        metadata: %{
          tool_name: "search_docs",
          description: "Search project docs",
          tool_call_id: "call-1"
        },
        started_at: ~U[2026-05-21 00:00:00Z]
      )

    output =
      Message.tool("found cats",
        name: "search_docs",
        tool_call_id: "call-1",
        status: :error,
        artifacts: [%{raw: true}],
        response_metadata: %{duration_ms: 12}
      )

    run = %{run | status: :ok, ended_at: ~U[2026-05-21 00:00:01Z], outputs: %{output: output}}

    payload = LangSmith.to_payload(:ok, run, "beam-weaver")

    assert payload.run_type == "tool"
    assert payload.serialized == %{name: "search_docs", description: "Search project docs"}

    assert payload.events == [
             %{name: "start", time: "2026-05-21T00:00:00Z"},
             %{name: "end", time: "2026-05-21T00:00:01Z"}
           ]

    assert payload.extra.tool_call_id == "call-1"

    assert payload.outputs.output == %{
             content: "found cats",
             type: "tool",
             name: "search_docs",
             tool_call_id: "call-1",
             artifact: %{raw: true},
             status: "error",
             additional_kwargs: %{},
             response_metadata: %{duration_ms: 12}
           }

    refute Map.has_key?(Map.from_struct(run), :serialized)
    refute Map.has_key?(Map.from_struct(run), :events)
  end

  test "graph LangSmith integration metadata is injected only in exported payloads" do
    run =
      Run.new("agent",
        id: "graph_run_compat",
        trace_id: "trace_graph_compat",
        kind: :graph,
        metadata: %{thread_id: "thread-1"},
        started_at: ~U[2026-05-21 00:00:00Z]
      )

    payload = LangSmith.to_payload(:started, run, "beam-weaver")

    assert payload.extra.metadata.thread_id == "thread-1"
    assert payload.extra.metadata.ls_integration == "langgraph"
    refute Map.has_key?(run.metadata, :ls_integration)
    refute Map.has_key?(run.metadata, "ls_integration")
  end

  test "payload derives child dotted_order from stored parent run" do
    Tracing.reset()
    on_exit(fn -> Tracing.reset() end)

    {:ok, parent} =
      Tracing.start_run("graph",
        id: "parent_run",
        trace_id: "parent_run",
        kind: :graph,
        started_at: ~U[2026-05-21 00:00:00Z]
      )

    {:ok, child} =
      Tracing.start_run("model",
        id: "child_run",
        kind: :model,
        started_at: ~U[2026-05-21 00:00:01Z]
      )

    parent_payload = LangSmith.to_payload(:started, parent, "beam-weaver")
    child_payload = LangSmith.to_payload(:started, child, "beam-weaver")

    assert child_payload.parent_run_id == parent_payload.id
    assert child_payload.trace_id == parent_payload.trace_id

    assert child_payload.dotted_order ==
             "#{parent_payload.dotted_order}.20260521T000001000000Z#{child_payload.id}"
  end

  test "graph chat model calls export LangSmith child llm runs with provider metadata and usage" do
    Process.register(self(), :langsmith_model_trace_test)

    BeamWeaver.TestSupport.ConfigHelper.merge_config(:tracing,
      exporter: BeamWeaver.Tracing.LangSmithModelTraceExporter
    )

    on_exit(fn ->
      safe_unregister(:langsmith_model_trace_test)
    end)

    usage = %{input_tokens: 3, output_tokens: 2, total_tokens: 5}

    model = %FakeChatModel{
      response:
        Message.assistant("summary",
          response_metadata: %{
            model_provider: "fake",
            model_name: "chat",
            finish_reason: "stop"
          },
          usage_metadata: usage
        )
    }

    graph =
      Graph.new()
      |> Graph.add_node(:model, fn state ->
        {:ok, message} =
          ChatModel.invoke(model, [Message.user(state.prompt)], temperature: 0.1, timeout: 15_000)

        %{messages: [message]}
      end)
      |> Graph.add_edge(Graph.start(), :model)
      |> Graph.add_edge(:model, Graph.end_node())
      |> Graph.compile!(name: "x_signal_desk.post_summary")

    assert {:ok, %{messages: [%Message{content: "summary"}]}} =
             Compiled.invoke(graph, %{prompt: "summarize these posts"})

    events = collect_trace_exports()
    graph_started = find_trace_event!(events, :started, :graph)
    model_started = find_trace_event!(events, :started, :model)
    model_finished = find_trace_event!(events, :ok, :model)

    assert model_started.parent_id == graph_started.id
    assert model_started.trace_id == graph_started.trace_id
    assert model_started.inputs == %{messages: [Message.user("summarize these posts")]}
    assert model_started.metadata.model_provider == "fake"
    assert model_started.metadata.model_name == "chat"
    assert model_started.metadata.ls_provider == "fake"
    assert model_started.metadata.ls_model_name == "chat"
    assert model_started.metadata.invocation_params.temperature == 0.1
    assert model_started.metadata.invocation_params.timeout == 15_000

    assert [%Message{content: "summary"} = finished_message] = model_finished.outputs.messages
    assert finished_message.usage_metadata == usage
    assert finished_message.response_metadata.model.provider == "fake"
    assert finished_message.response_metadata.usage == usage
    assert model_finished.outputs.usage_metadata == usage
    assert model_finished.usage == usage
    assert model_finished.metadata.usage_metadata == usage
    assert model_finished.metadata.finish_reason == "stop"

    payload =
      events
      |> Enum.map(fn {event, run} -> {event, run, []} end)
      |> LangSmith.to_batch_payload("beam-weaver")

    model_payload =
      payload.post
      |> Enum.find(&(&1.extra.metadata.beam_weaver_run_id == model_started.id))

    graph_payload = LangSmith.to_payload(:started, graph_started, "beam-weaver")

    assert model_payload.run_type == "llm"
    assert model_payload.parent_run_id == graph_payload.id
    assert model_payload.trace_id == graph_payload.trace_id

    assert [
             [
               %{
                 "lc" => 1,
                 "type" => "constructor",
                 "id" => ["langchain", "schema", "messages", "HumanMessage"],
                 "kwargs" => %{"content" => "summarize these posts", "type" => "human"}
               }
             ]
           ] = model_payload.inputs.messages

    encoded_usage = %{"input_tokens" => 3, "output_tokens" => 2, "total_tokens" => 5}

    assert [
             %{
               "role" => "assistant",
               "content" => "summary",
               "usage_metadata" => ^encoded_usage
             }
           ] = model_payload.outputs.messages

    assert [
             [
               %{
                 message: %{
                   "lc" => 1,
                   "type" => "constructor",
                   "id" => ["langchain", "schema", "messages", "AIMessage"],
                   "kwargs" => %{
                     "content" => "summary",
                     "type" => "ai",
                     "response_metadata" => %{
                       "model" => %{"provider" => "fake"},
                       "usage" => ^encoded_usage,
                       "finish_reason" => "stop"
                     },
                     "usage_metadata" => ^encoded_usage
                   }
                 }
               }
             ]
           ] = model_payload.outputs.generations

    assert model_payload.outputs.usage_metadata == usage
    assert model_payload.extra.model_provider == "fake"
    assert model_payload.extra.model_name == "chat"
    assert model_payload.extra.metadata.ls_integration == "langchain_chat_model"
    assert model_payload.extra.metadata.ls_message_format == "langchain"
    assert model_payload.extra.metadata.ls_provider == "fake"
    assert model_payload.extra.metadata.ls_model_name == "chat"
    assert model_payload.extra.metadata.usage_metadata == usage
    assert model_payload.extra.usage == usage
    assert model_payload.extra.invocation_params.temperature == 0.1
    assert model_payload.extra.invocation_params.timeout == 15_000
  end

  test "payload encoder makes arbitrary trace values JSON-safe like the LangSmith SDK" do
    run =
      Run.new("encoded",
        id: "encoded_1",
        trace_id: "trace_encoded",
        kind: :model,
        started_at: ~U[2026-05-21 00:00:00Z]
      )

    payload =
      LangSmith.to_payload(
        :ok,
        %{
          run
          | status: :ok,
            outputs: %{answer: {:ok, :done}, raw: <<255, 0, 1>>},
            metadata: %{
              seen_at: ~U[2026-05-21 01:02:03Z],
              days: MapSet.new([:monday, :tuesday]),
              tuple: {:a, 1},
              provider: :openai,
              model: :gpt_test,
              invalid_key: %{<<255>> => "binary key"}
            },
            usage: %{input_tokens: 3, bucket: :cached},
            tags: [:nightly, "langsmith"],
            inputs: [
              Message.user("hello",
                id: "msg-1",
                metadata: %{kind: :prompt, at: ~U[2026-05-21 01:02:03Z]}
              )
            ]
        },
        "beam-weaver"
      )

    assert is_binary(BeamWeaver.JSON.encode!(payload))

    assert [
             %{
               "role" => "user",
               "content" => "hello",
               "id" => "msg-1",
               "metadata" => %{"kind" => "prompt", "at" => "2026-05-21T01:02:03Z"}
             }
           ] = payload.inputs.value

    assert payload.outputs.answer == ["ok", "done"]
    assert payload.outputs.raw == %{"type" => "base64", "data" => "/wAB"}
    assert payload.extra.metadata.seen_at == "2026-05-21T01:02:03Z"
    assert Enum.sort(payload.extra.metadata.days) == ["monday", "tuesday"]
    assert payload.extra.metadata.tuple == ["a", 1]
    assert payload.extra.metadata.invalid_key["base64:/w=="] == "binary key"
    assert payload.extra.usage.bucket == "cached"
    assert payload.extra.model_provider == "openai"
    assert payload.extra.model_name == "gpt_test"
    assert payload.tags == ["nightly", "langsmith"]
  end

  test "payload encoder handles invalid binaries that passed through trace redaction" do
    run =
      Run.new("binary-input",
        id: "binary_1",
        trace_id: "trace_binary",
        kind: :tool,
        inputs: %{raw: <<255>>},
        started_at: ~U[2026-05-21 00:00:00Z]
      )

    payload = LangSmith.to_payload(:started, run, "beam-weaver")

    assert is_binary(BeamWeaver.JSON.encode!(payload))
    assert payload.inputs.raw == %{"type" => "base64", "data" => "/w=="}
  end

  test "payload serializes errors as LangSmith-compatible strings" do
    run =
      Run.new("failed",
        id: "error_1",
        trace_id: "trace_error",
        kind: :graph,
        started_at: ~U[2026-05-21 00:00:00Z]
      )

    run = %{run | status: :error, error: %{type: :boom, message: "bad"}}

    payload = LangSmith.to_payload(:error, run, "beam-weaver")

    assert is_binary(payload.error)
    assert payload.error =~ "boom"
    assert payload.error =~ "bad"
  end

  test "batch payload coalesces create and update operations like LangSmith SDK" do
    started =
      Run.new("graph",
        id: "graph_run_8",
        trace_id: "trace_graph",
        kind: :graph,
        inputs: %{question: "hi"},
        started_at: ~U[2026-05-22 00:00:00Z]
      )

    stream_event =
      Run.new("graph",
        id: "graph_run_8",
        trace_id: "trace_graph",
        kind: :graph,
        metadata: %{telemetry_event: "beam_weaver.stream.event"},
        started_at: ~U[2026-05-22 00:00:01Z]
      )
      |> Map.put(:status, :ok)
      |> Map.put(:ended_at, ~U[2026-05-22 00:00:01Z])

    finished =
      %{started | status: :ok, ended_at: ~U[2026-05-22 00:00:02Z], outputs: %{answer: "ok"}}

    payload =
      LangSmith.to_batch_payload(
        [
          {:started, started, []},
          {:ok, stream_event, []},
          {:ok, finished, []}
        ],
        "beam-weaver"
      )

    assert %{post: [post]} = payload
    refute Map.has_key?(payload, :patch)
    assert post.id =~ @uuid_regex
    assert post.extra.metadata.beam_weaver_run_id == "graph_run_8"
    assert post.status == "success"
    assert post.inputs == %{question: "hi"}
    assert post.outputs == %{answer: "ok"}
  end

  test "batch coalescing does not let empty updates erase real inputs or outputs" do
    started =
      Run.new("graph",
        id: "graph_run_preserve",
        trace_id: "trace_graph",
        kind: :graph,
        inputs: %{question: "hi"},
        started_at: ~U[2026-05-22 00:00:00Z]
      )

    finished =
      %{started | status: :ok, ended_at: ~U[2026-05-22 00:00:02Z], outputs: %{answer: "ok"}}

    late_metadata_update =
      Run.new("graph",
        id: "graph_run_preserve",
        trace_id: "trace_graph",
        kind: :graph,
        metadata: %{telemetry_event: "beam_weaver.stream.event"},
        started_at: ~U[2026-05-22 00:00:03Z]
      )
      |> Map.put(:status, :ok)
      |> Map.put(:ended_at, ~U[2026-05-22 00:00:03Z])

    payload =
      LangSmith.to_batch_payload(
        [
          {:started, started, []},
          {:ok, finished, []},
          {:ok, late_metadata_update, []}
        ],
        "beam-weaver"
      )

    assert %{post: [post]} = payload
    assert post.inputs == %{question: "hi"}
    assert post.outputs == %{answer: "ok"}
    assert post.extra.metadata.telemetry_event == "beam_weaver.stream.event"
  end

  test "batch payload sends finish-only run updates as patches" do
    run =
      Run.new("graph",
        id: "graph_run_patch",
        trace_id: "trace_patch",
        kind: :graph,
        inputs: %{question: "hi"},
        started_at: ~U[2026-05-22 00:00:00Z]
      )

    finished = %{run | status: :ok, ended_at: ~U[2026-05-22 00:00:02Z], outputs: %{answer: "ok"}}

    payload = LangSmith.to_batch_payload([{:ok, finished, []}], "beam-weaver")

    assert %{patch: [patch]} = payload
    refute Map.has_key?(payload, :post)
    assert patch.extra.metadata.beam_weaver_run_id == "graph_run_patch"
    assert patch.outputs == %{answer: "ok"}
  end

  test "non-success LangSmith responses include response body details" do
    first = Run.new("first", id: "body_1", trace_id: "trace_body", kind: :graph)
    second = Run.new("second", id: "body_2", trace_id: "trace_body", kind: :tool)

    assert {:error, {:langsmith_status, 422, %{response_body: %{"error" => "invalid batch JSON: expected object"}}}} =
             LangSmith.export_batch(
               [
                 {:ok, %{first | status: :ok}, []},
                 {:ok, %{second | status: :ok}, []}
               ],
               api_key: "test",
               project: "beam-weaver",
               transport: BeamWeaver.Tracing.LangSmithUnprocessableTransport
             )
  end

  test "LangSmith conflict responses are idempotent successes like the SDK" do
    run = Run.new("conflict", id: "conflict_1", trace_id: "trace_conflict", kind: :graph)

    assert :ok =
             LangSmith.export(:ok, %{run | status: :ok},
               api_key: "test",
               project: "beam-weaver",
               transport: BeamWeaver.Tracing.LangSmithConflictTransport
             )

    assert :ok =
             LangSmith.export_batch(
               [{:ok, %{run | status: :ok}, []}, {:ok, %{run | status: :ok}, []}],
               api_key: "test",
               project: "beam-weaver",
               transport: BeamWeaver.Tracing.LangSmithConflictTransport
             )
  end

  test "direct exporter creates starts and patches finishes" do
    Process.register(self(), :langsmith_capture_test)

    run =
      Run.new("direct",
        id: "direct_1",
        trace_id: "trace_direct",
        kind: :graph,
        inputs: %{question: "hi"},
        started_at: ~U[2026-05-22 00:00:00Z]
      )

    assert :ok =
             LangSmith.export(:started, run,
               api_key: "test",
               project: "beam-weaver",
               transport: BeamWeaver.Tracing.LangSmithCaptureTransport
             )

    assert_receive {:langsmith_post, post_url, created}
    assert String.ends_with?(post_url, "/runs")
    assert created.status == "pending"

    finished = %{run | status: :ok, ended_at: ~U[2026-05-22 00:00:02Z], outputs: %{answer: "ok"}}

    assert :ok =
             LangSmith.export(:ok, finished,
               api_key: "test",
               project: "beam-weaver",
               transport: BeamWeaver.Tracing.LangSmithCaptureTransport
             )

    assert_receive {:langsmith_patch, patch_url, patched}
    assert String.ends_with?(patch_url, "/runs/#{patched.id}")
    assert patched.status == "success"
    assert patched.outputs == %{answer: "ok"}

    Process.unregister(:langsmith_capture_test)
  end

  test "async queue exports runs without coupling runtime modules to LangSmith" do
    Process.register(self(), :langsmith_queue_test)

    {:ok, queue} =
      Queue.start_link(
        name: :langsmith_queue_test_queue,
        api_key: "test",
        project: "beam-weaver",
        transport: BeamWeaver.Tracing.LangSmithQueueTransport,
        batch_size: 2
      )

    run = Run.new("queued", id: "queued_1", trace_id: "trace_queued", kind: :graph)

    assert :ok = Queue.enqueue(queue, :ok, %{run | status: :ok, outputs: %{ok: true}})
    assert :ok = Queue.flush(queue)

    assert_receive {:langsmith_post, _url, payload}
    assert payload.id =~ @uuid_regex
    assert payload.extra.metadata.beam_weaver_run_id == "queued_1"
    assert payload.status == "success"

    Process.unregister(:langsmith_queue_test)
  end

  test "queued exporter carries traced inputs and outputs to LangSmith" do
    Process.register(self(), :langsmith_queue_test)

    {:ok, queue} =
      Queue.start_link(
        name: :langsmith_trace_exporter_queue,
        api_key: "test",
        project: "beam-weaver",
        transport: BeamWeaver.Tracing.LangSmithQueueTransport,
        batch_size: 10,
        flush_interval: 10_000
      )

    exporter_opts = [queue: queue]

    {:ok, run} =
      Tracing.start_run("x_signal_desk.post_summary",
        kind: :graph,
        inputs: %{post_ids: [7254, 7274]},
        exporter: Queue,
        exporter_opts: exporter_opts
      )

    assert {:ok, _finished} =
             Tracing.finish_run(run,
               outputs: %{summary: "market update"},
               exporter: Queue,
               exporter_opts: exporter_opts
             )

    assert :ok = Queue.flush(queue)

    assert_receive {:langsmith_post, _url, payload}
    assert %{post: [post]} = payload
    assert post.name == "x_signal_desk.post_summary"
    assert post.inputs == %{post_ids: [7254, 7274]}
    assert post.outputs == %{summary: "market update"}
    assert post.status == "success"

    GenServer.stop(queue)
    Process.unregister(:langsmith_queue_test)
  end

  test "queued exporter default aggregation window coalesces fast start and finish" do
    Process.register(self(), :langsmith_queue_test)

    {:ok, queue} =
      Queue.start_link(
        name: :langsmith_default_coalesce_queue,
        api_key: "test",
        project: "beam-weaver",
        transport: BeamWeaver.Tracing.LangSmithQueueTransport,
        batch_size: 10
      )

    exporter_opts = [queue: queue]

    {:ok, run} =
      Tracing.start_run("fast_graph",
        kind: :graph,
        inputs: %{question: "hi"},
        exporter: Queue,
        exporter_opts: exporter_opts
      )

    assert {:ok, _finished} =
             Tracing.finish_run(run,
               outputs: %{answer: "ok"},
               exporter: Queue,
               exporter_opts: exporter_opts
             )

    assert :ok = Queue.flush(queue)

    assert_receive {:langsmith_post, _url, payload}
    assert %{post: [post]} = payload
    refute Map.has_key?(payload, :patch)
    assert post.name == "fast_graph"
    assert post.inputs == %{question: "hi"}
    assert post.outputs == %{answer: "ok"}
    assert post.status == "success"

    GenServer.stop(queue)
    Process.unregister(:langsmith_queue_test)
  end

  test "queue batches, preserves order, and redacts before upload" do
    Process.register(self(), :langsmith_queue_test)

    {:ok, queue} =
      Queue.start_link(
        name: :langsmith_batch_queue,
        api_key: "test",
        project: "beam-weaver",
        transport: BeamWeaver.Tracing.LangSmithQueueTransport,
        batch_size: 2,
        flush_interval: 10_000,
        redactor: fn
          %{secret: _} = value -> Map.put(value, :secret, "[redacted]")
          value -> value
        end
      )

    first =
      Run.new("first",
        id: "run_first",
        trace_id: "trace_batch",
        kind: :model,
        inputs: %{secret: "token"},
        started_at: ~U[2026-05-22 00:00:00Z]
      )
      |> Map.put(:status, :ok)

    second =
      Run.new("second",
        id: "run_second",
        trace_id: "trace_batch",
        kind: :tool,
        inputs: %{value: 1},
        started_at: ~U[2026-05-22 00:00:01Z]
      )
      |> Map.put(:status, :ok)

    assert :ok = Queue.enqueue(queue, :ok, first)
    assert :ok = Queue.enqueue(queue, :ok, second)
    assert :ok = Queue.flush(queue)

    assert_receive {:langsmith_post, url, payload}
    assert String.ends_with?(url, "/runs/batch")
    payloads = Map.get(payload, :patch) || Map.get(payload, :post) || []

    assert Enum.map(payloads, & &1.extra.metadata.beam_weaver_run_id) == [
             "run_first",
             "run_second"
           ]

    assert hd(payloads).inputs.secret == "[redacted]"

    GenServer.stop(queue)
    Process.unregister(:langsmith_queue_test)
  end

  test "queue retries with backoff and dead-letters after max attempts" do
    {:ok, agent} = Agent.start_link(fn -> %{attempts: 0} end, name: :langsmith_flaky_state)

    {:ok, queue} =
      Queue.start_link(
        name: :langsmith_retry_queue,
        api_key: "test",
        project: "beam-weaver",
        transport: BeamWeaver.Tracing.LangSmithAlwaysFailTransport,
        retry_delay: 1,
        backoff: 1.0,
        jitter: 0.0,
        max_attempts: 2
      )

    run = Run.new("retry", id: "run_retry", trace_id: "trace_retry", kind: :graph)

    assert :ok = Queue.enqueue(queue, :ok, %{run | status: :ok})
    assert :ok = Queue.flush(queue)

    assert [%{run: %{id: "run_retry"}, attempts: 2, reason: :max_attempts}] =
             Queue.dead_letters(queue)

    assert Agent.get(agent, & &1.attempts) == 2

    GenServer.stop(queue)
    Agent.stop(agent)
  end

  test "queue upload failure telemetry includes LangSmith response body" do
    handler_id = "langsmith-queue-upload-body-#{System.unique_integer([:positive])}"
    parent = self()

    :telemetry.attach(
      handler_id,
      [:beam_weaver, :langsmith, :queue, :upload_failure],
      &__MODULE__.handle_langsmith_telemetry/4,
      parent
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {:ok, queue} =
      Queue.start_link(
        name: :langsmith_unprocessable_queue,
        api_key: "test",
        project: "beam-weaver",
        transport: BeamWeaver.Tracing.LangSmithUnprocessableTransport,
        flush_interval: 10_000,
        max_attempts: 1
      )

    run = Run.new("unprocessable", id: "run_unprocessable", trace_id: "trace_unprocessable")

    assert :ok = Queue.enqueue(queue, :ok, %{run | status: :ok})
    assert :ok = Queue.flush(queue)

    assert_receive {:langsmith_queue_event, [:beam_weaver, :langsmith, :queue, :upload_failure], %{count: 1},
                    %{operation: :upload_failure, run_id: "run_unprocessable", error: error}}

    assert error =~ "422"
    assert error =~ "response_body"
    assert error =~ "invalid batch JSON: expected object"

    GenServer.stop(queue)
  end

  test "queue treats LangSmith conflict responses as successful uploads" do
    handler_id = "langsmith-queue-conflict-#{System.unique_integer([:positive])}"
    parent = self()

    :telemetry.attach_many(
      handler_id,
      [
        [:beam_weaver, :langsmith, :queue, :upload_success],
        [:beam_weaver, :langsmith, :queue, :upload_failure]
      ],
      &__MODULE__.handle_langsmith_telemetry/4,
      parent
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {:ok, queue} =
      Queue.start_link(
        name: :langsmith_conflict_queue,
        api_key: "test",
        project: "beam-weaver",
        transport: BeamWeaver.Tracing.LangSmithConflictTransport,
        flush_interval: 10_000,
        max_attempts: 1
      )

    run = Run.new("conflict", id: "run_conflict", trace_id: "trace_conflict")

    assert :ok = Queue.enqueue(queue, :ok, %{run | status: :ok})
    assert :ok = Queue.flush(queue)

    assert_receive {:langsmith_queue_event, [:beam_weaver, :langsmith, :queue, :upload_success], %{count: 1},
                    %{operation: :upload_success, run_id: "run_conflict", result: :ok}}

    refute_receive {:langsmith_queue_event, [:beam_weaver, :langsmith, :queue, :upload_failure], _, _},
                   50

    assert [] = Queue.dead_letters(queue)

    GenServer.stop(queue)
  end

  test "queue overflow keeps bounded retention and records dropped items" do
    {:ok, queue} =
      Queue.start_link(
        name: :langsmith_overflow_queue,
        api_key: "test",
        project: "beam-weaver",
        transport: BeamWeaver.Tracing.LangSmithAlwaysFailTransport,
        max_items: 1,
        overflow: :drop_oldest,
        retry_delay: 10_000,
        max_attempts: 5
      )

    first = Run.new("old", id: "run_old", trace_id: "trace_overflow", kind: :graph)
    second = Run.new("new", id: "run_new", trace_id: "trace_overflow", kind: :graph)

    assert :ok = Queue.enqueue(queue, :ok, %{first | status: :ok})
    assert :ok = Queue.enqueue(queue, :ok, %{second | status: :ok})

    assert Enum.any?(Queue.dead_letters(queue), &(&1.reason == :dropped_oldest))

    GenServer.stop(queue)
  end

  test "queue is a no-op when no api key is configured" do
    Process.register(self(), :langsmith_queue_test)

    {:ok, queue} =
      Queue.start_link(
        name: :langsmith_no_key_queue,
        api_key: "",
        project: "beam-weaver",
        transport: BeamWeaver.Tracing.LangSmithQueueTransport
      )

    run = Run.new("no-key", id: "run_no_key", trace_id: "trace_no_key", kind: :graph)

    assert :ok = Queue.enqueue(queue, :ok, %{run | status: :ok})
    assert :ok = Queue.flush(queue)

    refute_receive {:langsmith_post, _url, _payload}, 50

    GenServer.stop(queue)
    Process.unregister(:langsmith_queue_test)
  end

  test "queue emits observability telemetry for enqueue, no-op upload, and flush lifecycle" do
    handler_id = "langsmith-queue-telemetry-#{System.unique_integer([:positive])}"
    parent = self()

    :telemetry.attach_many(
      handler_id,
      [
        [:beam_weaver, :langsmith, :queue, :enqueue],
        [:beam_weaver, :langsmith, :queue, :no_api_key],
        [:beam_weaver, :langsmith, :queue, :flush_start],
        [:beam_weaver, :langsmith, :queue, :flush_stop]
      ],
      &__MODULE__.handle_langsmith_telemetry/4,
      parent
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {:ok, queue} =
      Queue.start_link(
        name: :langsmith_observability_queue,
        api_key: "",
        project: "beam-weaver",
        flush_interval: 10_000
      )

    run = Run.new("no-key", id: "run_no_key_telemetry", trace_id: "trace_no_key", kind: :graph)

    assert :ok = Queue.enqueue(queue, :ok, %{run | status: :ok})
    assert :ok = Queue.flush(queue)

    assert_received {:langsmith_queue_event, [:beam_weaver, :langsmith, :queue, :enqueue], %{count: 1},
                     %{operation: :enqueue, run_id: "run_no_key_telemetry"}}

    assert_received {:langsmith_queue_event, [:beam_weaver, :langsmith, :queue, :flush_start], %{count: 1},
                     %{operation: :flush_start}}

    assert_received {:langsmith_queue_event, [:beam_weaver, :langsmith, :queue, :no_api_key], %{count: 1},
                     %{operation: :no_api_key, result: :noop}}

    assert_received {:langsmith_queue_event, [:beam_weaver, :langsmith, :queue, :flush_stop], %{count: 1},
                     %{operation: :flush_stop, result: :ok}}

    GenServer.stop(queue)
  end

  test "Queue.stop flushes before stopping and reports incomplete flush timeouts" do
    Process.register(self(), :langsmith_queue_test)

    {:ok, queue} =
      Queue.start_link(
        name: :langsmith_stop_queue,
        api_key: "test",
        project: "beam-weaver",
        transport: BeamWeaver.Tracing.LangSmithQueueTransport,
        flush_interval: 10_000
      )

    run = Run.new("stop", id: "run_stop", trace_id: "trace_stop", kind: :graph)

    assert :ok = Queue.enqueue(queue, :ok, %{run | status: :ok})
    assert :ok = Queue.stop(queue, timeout: 500)

    assert_receive {:langsmith_post, _url, payload}
    assert payload.id =~ @uuid_regex
    assert payload.extra.metadata.beam_weaver_run_id == "run_stop"
    refute Process.alive?(queue)

    Process.unregister(:langsmith_queue_test)

    {:ok, slow_queue} =
      Queue.start_link(
        name: :langsmith_slow_stop_queue,
        api_key: "test",
        project: "beam-weaver",
        transport: BeamWeaver.Tracing.LangSmithSlowTransport,
        flush_interval: 10_000
      )

    slow = Run.new("slow-stop", id: "run_slow_stop", trace_id: "trace_stop", kind: :graph)
    assert :ok = Queue.enqueue(slow_queue, :ok, %{slow | status: :ok})
    assert {:error, :langsmith_flush_incomplete} = Queue.stop(slow_queue, timeout: 10)

    Process.sleep(80)
    if Process.alive?(slow_queue), do: GenServer.stop(slow_queue)
  end

  test "batch 404 falls back to individual run uploads" do
    Process.register(self(), :langsmith_queue_test)

    {:ok, queue} =
      Queue.start_link(
        name: :langsmith_batch_fallback_queue,
        api_key: "test",
        project: "beam-weaver",
        transport: BeamWeaver.Tracing.LangSmithBatchFallbackTransport,
        batch_size: 2,
        flush_interval: 10_000
      )

    first = Run.new("first", id: "fallback_1", trace_id: "trace_fallback", kind: :graph)
    second = Run.new("second", id: "fallback_2", trace_id: "trace_fallback", kind: :tool)

    assert :ok = Queue.enqueue(queue, :ok, %{first | status: :ok})
    assert :ok = Queue.enqueue(queue, :ok, %{second | status: :ok})
    assert :ok = Queue.flush(queue)

    assert_receive {:langsmith_batch_attempt, payload}
    payloads = Map.get(payload, :patch) || Map.get(payload, :post) || []

    assert Enum.map(payloads, & &1.extra.metadata.beam_weaver_run_id) == [
             "fallback_1",
             "fallback_2"
           ]

    assert_receive {:langsmith_individual_post, payload_one}
    assert_receive {:langsmith_individual_post, payload_two}

    assert Enum.sort([
             payload_one.extra.metadata.beam_weaver_run_id,
             payload_two.extra.metadata.beam_weaver_run_id
           ]) == ["fallback_1", "fallback_2"]

    GenServer.stop(queue)
    Process.unregister(:langsmith_queue_test)
  end

  test "queue restores persisted items from its store and deletes them after flush" do
    Process.register(self(), :langsmith_queue_test)

    store = BeamWeaver.Tracing.Exporters.LangSmith.QueueStore.ETS.new()

    run =
      Run.new("persisted",
        id: "persisted_1",
        trace_id: "trace_persisted",
        kind: :graph,
        started_at: ~U[2026-05-22 00:00:00Z]
      )

    assert :ok =
             BeamWeaver.Tracing.Exporters.LangSmith.QueueStore.ETS.put(store, %{
               id: "queue_persisted_1",
               event: :ok,
               run: %{run | status: :ok, outputs: %{ok: true}},
               opts: [],
               attempts: 0,
               retry_at: System.monotonic_time(:millisecond),
               enqueued_at: System.system_time(:microsecond)
             })

    {:ok, queue} =
      Queue.start_link(
        name: :langsmith_restored_queue,
        api_key: "test",
        project: "beam-weaver",
        transport: BeamWeaver.Tracing.LangSmithQueueTransport,
        store: store,
        flush_interval: 10_000
      )

    assert :ok = Queue.flush(queue)
    assert_receive {:langsmith_post, _url, payload}
    assert payload.id =~ @uuid_regex
    assert payload.extra.metadata.beam_weaver_run_id == "persisted_1"
    assert [] = BeamWeaver.Tracing.Exporters.LangSmith.QueueStore.ETS.list(store, [])

    GenServer.stop(queue)
    Process.unregister(:langsmith_queue_test)
  end

  test "telemetry subscriber does not export stream events as pseudo-runs" do
    Process.register(self(), :langsmith_queue_test)

    {:ok, queue} =
      Queue.start_link(
        name: :langsmith_telemetry_queue,
        api_key: "test",
        project: "beam-weaver",
        transport: BeamWeaver.Tracing.LangSmithQueueTransport,
        flush_interval: 10_000
      )

    {:ok, subscriber} =
      TelemetrySubscriber.start_link(
        name: :langsmith_telemetry_subscriber,
        id: "langsmith-telemetry-test",
        queue: queue
      )

    :telemetry.execute([:beam_weaver, :stream, :event], %{count: 1}, %{
      run_id: "run_stream",
      graph: "Graph",
      node: "node",
      model_provider: :openai,
      model_name: "gpt-test"
    })

    assert :ok = Queue.flush(queue)
    refute_receive {:langsmith_post, _url, _payload}, 50

    GenServer.stop(subscriber)
    GenServer.stop(queue)
    Process.unregister(:langsmith_queue_test)
  end

  test "telemetry subscriber does not duplicate graph lifecycle traces" do
    Process.register(self(), :langsmith_queue_test)

    {:ok, queue} =
      Queue.start_link(
        name: :langsmith_graph_lifecycle_telemetry_queue,
        api_key: "test",
        project: "beam-weaver",
        transport: BeamWeaver.Tracing.LangSmithQueueTransport,
        flush_interval: 10_000
      )

    {:ok, subscriber} =
      TelemetrySubscriber.start_link(
        name: :langsmith_graph_lifecycle_telemetry_subscriber,
        id: "langsmith-graph-lifecycle-telemetry-test",
        queue: queue
      )

    :telemetry.execute([:beam_weaver, :graph, :start], %{system_time: 1}, %{
      run_id: "run_graph_start",
      graph: "Graph"
    })

    assert :ok = Queue.flush(queue)
    refute_receive {:langsmith_post, _url, _payload}, 50

    GenServer.stop(subscriber)
    GenServer.stop(queue)
    Process.unregister(:langsmith_queue_test)
  end

  test "telemetry subscriber maps adapter and model events into LangSmith metadata" do
    Process.register(self(), :langsmith_queue_test)

    {:ok, queue} =
      Queue.start_link(
        name: :langsmith_adapter_telemetry_queue,
        api_key: "test",
        project: "beam-weaver",
        transport: BeamWeaver.Tracing.LangSmithQueueTransport,
        batch_size: 10,
        flush_interval: 10_000
      )

    {:ok, subscriber} =
      TelemetrySubscriber.start_link(
        name: :langsmith_adapter_telemetry_subscriber,
        id: "langsmith-adapter-telemetry-test",
        queue: queue
      )

    :telemetry.execute([:beam_weaver, :checkpoint, :put], %{count: 1}, %{
      run_id: "run_checkpoint_event",
      operation: :put,
      thread_id: "thread-1",
      checkpoint_id: "cp-1",
      source: "loop"
    })

    :telemetry.execute([:beam_weaver, :cache, :hit], %{count: 1}, %{
      run_id: "run_cache_event",
      operation: :hit,
      namespace: [:tenant],
      key: "prompt",
      result: :hit
    })

    :telemetry.execute([:beam_weaver, :memory, :search], %{count: 2}, %{
      run_id: "run_memory_event",
      operation: :search,
      namespace: ["users"],
      filter: %{kind: "preference"},
      result: :ok
    })

    :telemetry.execute([:beam_weaver, :vector_store, :similarity_search], %{count: 2}, %{
      run_id: "run_vector_event",
      operation: :similarity_search,
      namespace: "tenant-a",
      query: "docs",
      k: 3,
      result: :ok
    })

    :telemetry.execute([:beam_weaver, :models, :param_warning], %{count: 1}, %{
      run_id: "run_model_event",
      provider: :openai,
      model: "gpt-test",
      invocation_params: %{temperature: 0.2}
    })

    assert :ok = Queue.flush(queue)

    assert_receive {:langsmith_post, _url, payloads}
    payloads = Map.get(payloads, :patch) || Map.get(payloads, :post) || []
    ids = Map.new(payloads, &{&1.extra.metadata.beam_weaver_run_id, &1})

    assert ids["run_checkpoint_event"].extra.metadata.telemetry_event ==
             "beam_weaver.checkpoint.put"

    assert ids["run_checkpoint_event"].extra.metadata.thread_id == "thread-1"
    assert ids["run_cache_event"].extra.metadata.result == "hit"
    assert ids["run_memory_event"].extra.metadata.filter == %{kind: "preference"}
    assert ids["run_vector_event"].extra.metadata.k == 3
    assert ids["run_model_event"].extra.model_provider == "openai"
    assert ids["run_model_event"].extra.model_name == "gpt-test"
    assert ids["run_model_event"].extra.invocation_params == %{temperature: 0.2}

    GenServer.stop(subscriber)
    GenServer.stop(queue)
    Process.unregister(:langsmith_queue_test)
  end

  def handle_langsmith_telemetry(event, measurements, metadata, parent) do
    send(parent, {:langsmith_queue_event, event, measurements, metadata})
  end

  defp collect_trace_exports(acc \\ []) do
    receive do
      {:trace_export, event, run} -> collect_trace_exports([{event, run} | acc])
    after
      100 -> Enum.reverse(acc)
    end
  end

  defp find_trace_event!(events, event, kind) do
    Enum.find_value(events, fn
      {^event, %{kind: ^kind} = run} -> run
      _other -> nil
    end) || flunk("expected #{inspect(event)} #{inspect(kind)} trace event in #{inspect(events)}")
  end

  defp safe_unregister(name) do
    if Process.whereis(name), do: Process.unregister(name)
  end
end

defmodule BeamWeaver.Tracing.LangSmithModelTraceExporter do
  def export(event, run, _opts) do
    if pid = Process.whereis(:langsmith_model_trace_test) do
      send(pid, {:trace_export, event, run})
    end

    :ok
  end
end

defmodule BeamWeaver.Tracing.LangSmithQueueTransport do
  def post(url, opts) do
    send(
      Process.whereis(:langsmith_queue_test),
      {:langsmith_post, url, Keyword.fetch!(opts, :json)}
    )

    {:ok, %{status: 202}}
  end

  def patch(url, opts) do
    post(url, opts)
  end
end

defmodule BeamWeaver.Tracing.LangSmithAlwaysFailTransport do
  def post(_url, _opts) do
    if Process.whereis(:langsmith_flaky_state) do
      Agent.update(:langsmith_flaky_state, &Map.update!(&1, :attempts, fn count -> count + 1 end))
    end

    {:error, :temporary_failure}
  end

  def patch(url, opts), do: post(url, opts)
end

defmodule BeamWeaver.Tracing.LangSmithBatchFallbackTransport do
  def post(url, opts) do
    json = Keyword.fetch!(opts, :json)

    if String.ends_with?(url, "/runs/batch") do
      send(Process.whereis(:langsmith_queue_test), {:langsmith_batch_attempt, json})
      {:ok, %{status: 404}}
    else
      send(Process.whereis(:langsmith_queue_test), {:langsmith_individual_post, json})
      {:ok, %{status: 202}}
    end
  end

  def patch(_url, opts) do
    send(
      Process.whereis(:langsmith_queue_test),
      {:langsmith_individual_post, Keyword.fetch!(opts, :json)}
    )

    {:ok, %{status: 202}}
  end
end

defmodule BeamWeaver.Tracing.LangSmithUnprocessableTransport do
  def post(_url, _opts) do
    {:ok, %{status: 422, body: %{"error" => "invalid batch JSON: expected object"}}}
  end

  def patch(url, opts), do: post(url, opts)
end

defmodule BeamWeaver.Tracing.LangSmithConflictTransport do
  def post(_url, _opts) do
    {:ok, %{status: 409, body: %{"error" => "payloads already received"}}}
  end

  def patch(url, opts), do: post(url, opts)
end

defmodule BeamWeaver.Tracing.LangSmithCaptureTransport do
  def post(url, opts) do
    send(
      Process.whereis(:langsmith_capture_test),
      {:langsmith_post, url, Keyword.fetch!(opts, :json)}
    )

    {:ok, %{status: 202}}
  end

  def patch(url, opts) do
    send(
      Process.whereis(:langsmith_capture_test),
      {:langsmith_patch, url, Keyword.fetch!(opts, :json)}
    )

    {:ok, %{status: 202}}
  end
end

defmodule BeamWeaver.Tracing.LangSmithSlowTransport do
  def post(_url, _opts) do
    Process.sleep(50)
    {:ok, %{status: 202}}
  end

  def patch(url, opts), do: post(url, opts)
end
