defmodule BeamWeaver.Tracing.LangSmithExporterTest do
  use ExUnit.Case, async: false

  alias BeamWeaver.Core.ChatModel
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Messages
  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Graph
  alias BeamWeaver.Graph.Command
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

    assert payload.extra.invocation_params == %{
             _type: "openai-chat",
             model: "gpt-test",
             model_name: "gpt-test",
             temperature: 0.2
           }

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

  test "tool payloads prefer executable call ids over provider ids" do
    run =
      Run.new("crm_sync",
        id: "tool_run_call_id",
        trace_id: "trace_tool_call_id",
        kind: :tool,
        metadata: %{
          tool_name: "crm_sync",
          call_id: "call-crm-sync",
          id: "local-crm-sync",
          provider_id: "fc_crm_sync"
        },
        started_at: ~U[2026-05-21 00:00:00Z]
      )

    payload =
      LangSmith.to_payload(
        :ok,
        %{run | status: :ok, ended_at: ~U[2026-05-21 00:00:01Z], outputs: %{output: %{ok: true}}},
        "beam-weaver"
      )

    assert payload.extra.tool_call_id == "call-crm-sync"
    assert payload.outputs.output.tool_call_id == "call-crm-sync"
  end

  test "model payloads expose LangSmith tool schemas and project subagent task calls" do
    tool_schema = %{
      "type" => "function",
      "function" => %{
        "name" => "run_narrative_compressor",
        "description" => "Run the narrative compressor subagent with verification.",
        "parameters" => %{"type" => "object", "properties" => %{}, "additionalProperties" => false},
        "strict" => true
      }
    }

    message =
      Message.assistant("",
        tool_calls: [
          Messages.tool_call(
            id: "call-narrative",
            name: "task",
            args: %{
              "description" => "long supervisor prompt",
              "subagent_name" => "narrative_compressor"
            }
          )
        ],
        usage_metadata: %{input_tokens: 10, output_tokens: 2, total_tokens: 12},
        response_metadata: %{model_provider: "google", model_name: "gemini-3.5-flash"}
      )

    run =
      Run.new("google:gemini-3.5-flash",
        id: "model_subagent_task",
        trace_id: "trace_subagent_task",
        kind: :model,
        metadata: %{
          invocation_params: %{
            temperature: 0.2,
            tools: [tool_schema],
            response_format: %{"type" => "json_object"}
          },
          model_provider: "google",
          model_name: "gemini-3.5-flash"
        },
        started_at: ~U[2026-05-21 00:00:00Z]
      )

    payload =
      LangSmith.to_payload(
        :ok,
        %{run | status: :ok, ended_at: ~U[2026-05-21 00:00:01Z], outputs: %{messages: [message]}},
        "beam-weaver"
      )

    assert payload.extra.invocation_params.tools == [tool_schema]
    assert payload.extra.invocation_params.response_format == %{"type" => "json_object"}
    assert payload.outputs.llm_output.token_usage == %{prompt_tokens: 10, completion_tokens: 2, total_tokens: 12}

    assert [
             [
               %{
                 message: %{
                   "kwargs" => %{
                     "tool_calls" => [
                       %{"name" => "run_narrative_compressor", "args" => %{}, "id" => "call-narrative"}
                     ]
                   }
                 }
               }
             ]
           ] = payload.outputs.generations
  end

  test "chat model trace metadata stays neutral and LangSmith export renders virtual tool schemas" do
    Process.register(self(), :langsmith_model_trace_test)

    BeamWeaver.TestSupport.ConfigHelper.merge_config(:tracing,
      exporter: BeamWeaver.Tracing.LangSmithModelTraceExporter
    )

    on_exit(fn ->
      safe_unregister(:langsmith_model_trace_test)
    end)

    trace_tool = %{
      name: "run_fact_extractor",
      description: "Run the fact extractor subagent with verification.",
      input_schema: %{"type" => "object", "properties" => %{}, "additionalProperties" => false},
      strict: true
    }

    langsmith_tool = %{
      "type" => "function",
      "function" => %{
        "name" => "run_fact_extractor",
        "description" => "Run the fact extractor subagent with verification.",
        "parameters" => %{"type" => "object", "properties" => %{}, "additionalProperties" => false},
        "strict" => true
      }
    }

    task_tool =
      Tool.from_function!(
        name: "task",
        description: "Launch a subagent.",
        input_schema: %{
          "type" => "object",
          "properties" => %{"description" => %{"type" => "string"}},
          "required" => ["description"]
        },
        metadata: %{trace_tools: [trace_tool]},
        handler: fn _input, _opts -> {:ok, "done"} end
      )

    model = %FakeChatModel{response: Message.assistant("ok")}

    assert {:ok, %Message{}} =
             ChatModel.invoke(model, [Message.user("hi")],
               tools: [task_tool],
               response_format: %{"type" => "json_object"},
               temperature: 0.2
             )

    events = collect_trace_exports()
    model_started = find_trace_event!(events, :started, :model)

    assert model_started.metadata.tool_definitions == [trace_tool]
    assert model_started.metadata.invocation_params.response_format == %{"type" => "json_object"}
    refute Map.has_key?(model_started.metadata.invocation_params, :tools)
    refute Map.has_key?(model_started.metadata.invocation_params, :_type)

    payload = LangSmith.to_payload(:started, model_started, "beam-weaver")

    assert payload.extra.invocation_params.tools == [langsmith_tool]
    assert payload.extra.invocation_params.response_format == %{"type" => "json_object"}
  end

  test "LangSmith invocation params map Moonshot Kimi at the exporter boundary" do
    run =
      Run.new("moonshot:kimi-k2.6",
        id: "llm_kimi_invocation",
        trace_id: "trace_kimi_invocation",
        kind: :model,
        metadata: %{
          provider: "moonshot",
          model: "kimi-k2.6",
          invocation_params: %{temperature: 0.2}
        },
        started_at: ~U[2026-05-21 00:00:00Z]
      )

    payload = LangSmith.to_payload(:started, run, "beam-weaver")

    assert payload.extra.invocation_params == %{
             _type: "openai-chat",
             model: "kimi-k2.6",
             model_name: "kimi-k2.6",
             temperature: 0.2
           }

    assert payload.serialized["id"] == ["langchain", "chat_models", "openai", "moonshot:kimi-k2.6"]
  end

  test "chat model invocation metadata normalizes structured output to response format" do
    Process.register(self(), :langsmith_model_trace_test)

    BeamWeaver.TestSupport.ConfigHelper.merge_config(:tracing,
      exporter: BeamWeaver.Tracing.LangSmithModelTraceExporter
    )

    on_exit(fn ->
      safe_unregister(:langsmith_model_trace_test)
    end)

    response_format = %{
      "type" => "json_schema",
      "json_schema" => %{
        "name" => "answer",
        "schema" => %{"type" => "object", "properties" => %{"ok" => %{"type" => "boolean"}}}
      }
    }

    model = %FakeChatModel{response: Message.assistant(~s({"ok":true}))}

    assert {:ok, %Message{}} =
             ChatModel.invoke(model, [Message.user("hi")],
               structured_output: response_format,
               temperature: 0.2
             )

    events = collect_trace_exports()
    model_started = find_trace_event!(events, :started, :model)

    assert model_started.metadata.invocation_params.response_format == response_format
    refute Map.has_key?(model_started.metadata.invocation_params, :structured_output)
  end

  test "captured subagent task tool runs export compact parent-visible messages" do
    tool_message =
      Message.tool(~s({"status":"captured","subagent_name":"narrative_compressor"}),
        name: "task",
        tool_call_id: "call-narrative",
        metadata: %{subagent_name: "narrative_compressor", kind: :subagent_result}
      )

    command =
      %Command{
        update: %{
          messages: [tool_message],
          subagent_outputs: %{"narrative_output" => %{"large" => "captured outside transcript"}}
        }
      }

    run =
      Run.new("task",
        id: "tool_subagent_task",
        trace_id: "trace_subagent_task",
        kind: :tool,
        inputs: %{subagent_name: "narrative_compressor", description: "long supervisor prompt"},
        metadata: %{tool_name: "task", tool_call_id: "call-narrative"},
        started_at: ~U[2026-05-21 00:00:00Z]
      )

    payload =
      LangSmith.to_payload(
        :ok,
        %{run | status: :ok, ended_at: ~U[2026-05-21 00:00:01Z], outputs: %{output: command}},
        "beam-weaver"
      )

    assert payload.name == "run_narrative_compressor"
    assert payload.serialized.name == "run_narrative_compressor"
    assert payload.outputs.output.name == "run_narrative_compressor"
    assert payload.outputs.output.content == ~s({"status":"captured","subagent_name":"narrative_compressor"})
    refute payload.outputs.output.content =~ "captured outside transcript"
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
             [
               %{
                 text: "summary",
                 type: "ChatGeneration",
                 generation_info: %{finish_reason: "stop", logprobs: nil},
                 message: %{
                   "lc" => 1,
                   "type" => "constructor",
                   "id" => ["langchain", "schema", "messages", "AIMessage"],
                   "kwargs" => %{
                     "content" => "summary",
                     "type" => "ai",
                     "response_metadata" => %{
                       "usage" => ^encoded_usage,
                       "finish_reason" => "stop"
                     },
                     "usage_metadata" => ^encoded_usage
                   }
                 }
               }
             ]
           ] = model_payload.outputs.generations

    assert model_payload.outputs.type == "LLMResult"
    assert model_payload.outputs.llm_output.model_provider == "fake"
    assert model_payload.outputs.llm_output.model_name == "chat"
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

  test "model outputs use LangChain LLMResult shape and executable tool-call ids" do
    message =
      Message.assistant("",
        response_metadata: %{
          finish_reason: "tool_calls",
          token_usage: %{prompt_tokens: 10, completion_tokens: 2, total_tokens: 12},
          model_provider: "openai",
          model_name: "gpt-test",
          id: "response-1"
        },
        usage_metadata: %{input_tokens: 10, output_tokens: 2, total_tokens: 12},
        tool_calls: [
          Messages.tool_call(
            id: "task_0",
            provider_id: "task:0",
            call_id: "call-task-0",
            name: "task",
            args: %{description: "do work"}
          )
        ]
      )

    run =
      Run.new("ChatOpenAIForXAI",
        id: "llm_tool_call",
        trace_id: "trace_tool_call",
        kind: :model,
        inputs: %{messages: [Message.user("hi")]},
        metadata: %{provider: "openai", model: "gpt-test"},
        started_at: ~U[2026-05-21 00:00:00Z]
      )

    payload =
      LangSmith.to_payload(
        :ok,
        %{run | status: :ok, ended_at: ~U[2026-05-21 00:00:01Z], outputs: %{messages: [message]}},
        "beam-weaver"
      )

    assert payload.outputs.type == "LLMResult"
    refute Map.has_key?(payload.outputs, :messages)

    assert [
             [
               %{
                 text: "",
                 type: "ChatGeneration",
                 generation_info: %{finish_reason: "tool_calls", logprobs: nil},
                 message: %{
                   "kwargs" => %{
                     "tool_calls" => [
                       %{
                         "id" => "call-task-0",
                         "name" => "task",
                         "args" => %{"description" => "do work"},
                         "type" => "tool_call"
                       }
                     ]
                   }
                 }
               }
             ]
           ] = payload.outputs.generations

    refute payload.outputs.generations
           |> hd()
           |> hd()
           |> get_in([:message, "kwargs", "tool_calls"])
           |> hd()
           |> Map.has_key?("provider_id")

    assert payload.outputs.llm_output == %{
             token_usage: %{prompt_tokens: 10, completion_tokens: 2, total_tokens: 12},
             model_provider: "openai",
             model_name: "gpt-test",
             id: "response-1"
           }

    assert payload.serialized["id"] == ["langchain", "chat_models", "openai", "ChatOpenAIForXAI"]
  end

  test "structured-output schema calls are not exported as executable tool calls" do
    message =
      Message.assistant(
        [
          %{type: "reasoning", text: "prepare structured answer"},
          %{type: "tool_call", name: "answer", call_id: "call-answer", arguments: "{\"ok\":true}"},
          %{type: "function_call", name: "search", call_id: "call-search", arguments: "{\"q\":\"docs\"}"}
        ],
        response_metadata: %{finish_reason: "tool_calls"},
        tool_calls: [
          Messages.tool_call(id: "call-answer", name: "answer", args: %{ok: true}),
          Messages.tool_call(id: "call-search", name: "search", args: %{q: "docs"})
        ]
      )

    run =
      Run.new("ChatOpenAIForXAI",
        id: "llm_structured_tool_call",
        trace_id: "trace_structured_tool_call",
        kind: :model,
        inputs: %{messages: [Message.user("hi")]},
        metadata: %{
          provider: "openai",
          model: "gpt-test",
          structured_output_strategy: :tool,
          structured_output_tool_names: ["answer"]
        },
        started_at: ~U[2026-05-21 00:00:00Z]
      )

    payload =
      LangSmith.to_payload(
        :ok,
        %{run | status: :ok, ended_at: ~U[2026-05-21 00:00:01Z], outputs: %{messages: [message]}},
        "beam-weaver"
      )

    kwargs =
      payload.outputs.generations
      |> hd()
      |> hd()
      |> get_in([:message, "kwargs"])

    assert kwargs["tool_calls"] == [
             %{
               "id" => "call-search",
               "name" => "search",
               "args" => %{"q" => "docs"},
               "type" => "tool_call"
             }
           ]

    assert kwargs["content"] == [
             %{"metadata" => %{}, "reasoning" => "prepare structured answer", "type" => "reasoning"}
           ]
  end

  test "structured-output schema call stripping normalizes atom schema names" do
    message =
      Message.assistant(
        [
          %{type: :function_call, name: "answer", call_id: "call-answer", arguments: "{\"ok\":true}"},
          %{type: :function_call, name: "search", call_id: "call-search", arguments: "{\"q\":\"docs\"}"}
        ],
        response_metadata: %{finish_reason: "tool_calls"},
        tool_calls: [
          Messages.tool_call(id: "call-answer", name: "answer", args: %{ok: true}),
          Messages.tool_call(id: "call-search", name: "search", args: %{q: "docs"})
        ]
      )

    run =
      Run.new("ChatOpenAIForXAI",
        id: "llm_structured_atom_name",
        trace_id: "trace_structured_atom_name",
        kind: :model,
        inputs: %{messages: [Message.user("hi")]},
        metadata: %{
          provider: "openai",
          model: "gpt-test",
          structured_output_strategy: :tool,
          structured_output_tool_names: [:answer]
        },
        started_at: ~U[2026-05-21 00:00:00Z]
      )

    payload =
      LangSmith.to_payload(
        :ok,
        %{run | status: :ok, ended_at: ~U[2026-05-21 00:00:01Z], outputs: %{messages: [message]}},
        "beam-weaver"
      )

    kwargs =
      payload.outputs.generations
      |> hd()
      |> hd()
      |> get_in([:message, "kwargs"])

    assert kwargs["tool_calls"] == [
             %{
               "id" => "call-search",
               "name" => "search",
               "args" => %{"q" => "docs"},
               "type" => "tool_call"
             }
           ]

    refute Map.has_key?(kwargs, "content")
  end

  test "chain message outputs strip provider call blocks and raw response metadata" do
    message =
      Message.assistant(
        [
          %{
            type: "reasoning",
            text: "prepare structured answer",
            raw_provider_block: %{id: "rs_1", type: "reasoning"}
          },
          %{
            type: "function_call",
            name: "answer",
            call_id: "call-answer",
            raw_provider_block: %{id: "fc_1", type: "function_call"}
          }
        ],
        metadata: %{
          structured_output_strategy: :tool,
          structured_output_tool_names: ["answer"]
        },
        response_metadata: %{
          finish_reason: "tool_calls",
          output: [%{name: "answer", type: "function_call"}],
          tooling: %{tool_calls: [%{name: "answer", id: "call-answer"}]},
          raw_provider_response: %{output: [%{name: "answer"}]},
          provider_metadata: %{raw: %{output: [%{name: "answer"}]}},
          model_provider: "openai"
        },
        tool_calls: [
          Messages.tool_call(id: "call-answer", name: "answer", args: %{ok: true})
        ]
      )

    run =
      Run.new("agent",
        id: "chain_structured_output",
        trace_id: "trace_structured_output",
        kind: :graph,
        inputs: %{
          __node_outputs__: %{
            model: %{messages: [message]}
          },
          messages: [Message.user("hi")]
        },
        metadata: %{
          __edge_runs__: %{model: "internal"},
          response_metadata: %{
            output: [%{name: "answer"}],
            raw_provider_response: %{output: [%{name: "answer"}]},
            provider_metadata: %{raw: %{output: [%{name: "answer"}]}}
          }
        },
        started_at: ~U[2026-05-21 00:00:00Z]
      )

    payload =
      LangSmith.to_payload(
        :ok,
        %{
          run
          | status: :ok,
            ended_at: ~U[2026-05-21 00:00:01Z],
            outputs: %{messages: [message]}
        },
        "beam-weaver"
      )

    assert [message_payload] = payload.outputs.messages
    assert message_payload.type == "ai"
    assert message_payload.content == [%{"reasoning" => "prepare structured answer", "type" => "reasoning"}]
    assert message_payload.response_metadata == %{"finish_reason" => "tool_calls", "model_provider" => "openai"}
    refute Map.has_key?(message_payload, :tool_calls)
    assert payload.extra.metadata.response_metadata == %{}
    refute Map.has_key?(payload.extra.metadata, :__edge_runs__)
    refute Map.has_key?(payload.inputs, :__node_outputs__)
  end

  test "graph payloads hide runtime state channels from LangSmith inputs and outputs" do
    run =
      Run.new("agent",
        id: "graph_runtime_state",
        trace_id: "trace_runtime_state",
        kind: :graph,
        inputs: %{
          messages: [Message.user("hi")],
          remaining_steps: 998,
          tool_set: %{tools: %{task: %{handler: "#Function<0.1.2>"}}},
          usage: %{model_calls: 1},
          nested: %{thread_tool_call_count: %{task: 1}}
        },
        started_at: ~U[2026-05-21 00:00:00Z]
      )

    payload =
      LangSmith.to_payload(
        :ok,
        %{
          run
          | status: :ok,
            ended_at: ~U[2026-05-21 00:00:01Z],
            outputs: %{
              messages: [Message.assistant("done")],
              subagent_outputs: %{narrative_output: %{large: "captured"}},
              subagent_cache: %{cached: true},
              run_tool_call_count: %{task: 1}
            }
        },
        "beam-weaver"
      )

    assert [%{type: "human", content: "hi"}] = payload.inputs.messages
    assert [%{type: "ai", content: "done"}] = payload.outputs.messages

    refute Map.has_key?(payload.inputs, :remaining_steps)
    refute Map.has_key?(payload.inputs, :tool_set)
    refute Map.has_key?(payload.inputs, :usage)
    assert payload.inputs.nested == %{}

    refute Map.has_key?(payload.outputs, :subagent_outputs)
    refute Map.has_key?(payload.outputs, :subagent_cache)
    refute Map.has_key?(payload.outputs, :run_tool_call_count)
  end

  test "llm output normalizes nested provider model metadata to strings" do
    message =
      Message.assistant("ok",
        response_metadata: %{
          model_provider: %{provider: "xai", model_provider: "xai"},
          model_name: %{
            model: "grok-4.3",
            model_name: "grok-4.3",
            requested_model: "xai:grok-4.3"
          },
          token_usage: %{prompt_tokens: 1, completion_tokens: 1}
        }
      )

    run =
      Run.new("xai:grok-4.3",
        id: "llm_nested_model_metadata",
        trace_id: "trace_nested_model_metadata",
        kind: :model,
        metadata: %{
          model_provider: %{provider: "xai"},
          model_name: %{model_name: "grok-4.3"},
          invocation_params: %{model: %{model_name: "grok-4.3"}}
        },
        started_at: ~U[2026-05-21 00:00:00Z]
      )

    payload =
      LangSmith.to_payload(
        :ok,
        %{
          run
          | status: :ok,
            ended_at: ~U[2026-05-21 00:00:01Z],
            outputs: %{messages: [message]}
        },
        "beam-weaver"
      )

    assert payload.outputs.llm_output.model_provider == "xai"
    assert payload.outputs.llm_output.model_name == "grok-4.3"
    assert payload.extra.model_provider == "xai"
    assert payload.extra.model_name == "grok-4.3"
    assert payload.serialized["kwargs"]["model_name"] == "grok-4.3"
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
    assert %{patch: [patch]} = payload
    assert patch.id =~ @uuid_regex
    assert patch.extra.metadata.beam_weaver_run_id == "queued_1"
    refute Map.has_key?(patch, :status)
    assert patch.session_id == nil

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
    assert %{post: [post], patch: [patch]} = payload
    assert post.name == "x_signal_desk.post_summary"
    assert post.inputs == %{post_ids: [7254, 7274]}
    assert post.outputs == %{}
    assert post.replicas == []
    refute Map.has_key?(post, :status)
    assert patch.outputs == %{summary: "market update"}
    assert patch.session_id == nil
    refute Map.has_key?(patch, :status)

    GenServer.stop(queue)
    Process.unregister(:langsmith_queue_test)
  end

  test "queued exporter preserves start and finish operations in multipart payloads" do
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
    assert %{post: [post], patch: [patch]} = payload
    assert post.name == "fast_graph"
    assert post.inputs == %{question: "hi"}
    assert post.outputs == %{}
    assert post.replicas == []
    refute Map.has_key?(post, :status)
    assert patch.name == "fast_graph"
    assert patch.outputs == %{answer: "ok"}
    assert patch.session_id == nil
    refute Map.has_key?(patch, :status)

    GenServer.stop(queue)
    Process.unregister(:langsmith_queue_test)
  end

  test "multipart uploads expose redacted Beam Weaver request metadata through finch_private" do
    Process.register(self(), :langsmith_queue_test)

    {:ok, queue} =
      Queue.start_link(
        name: :langsmith_finch_private_queue,
        api_key: "test",
        project: "beam-weaver",
        transport: BeamWeaver.Tracing.LangSmithQueueOptionsTransport,
        batch_size: 10,
        flush_interval: 10_000
      )

    run = Run.new("queued", id: "queued_private", trace_id: "trace_private", kind: :graph)

    assert :ok = Queue.enqueue(queue, :started, run)
    assert :ok = Queue.flush(queue)

    assert_receive {:langsmith_post_opts, url, opts}
    assert String.ends_with?(url, "/runs/multipart")
    assert {"user-agent", user_agent} = Enum.find(Keyword.fetch!(opts, :headers), &(elem(&1, 0) == "user-agent"))
    assert user_agent =~ "beam-weaver/"

    assert [beam_weaver: metadata] = Keyword.fetch!(opts, :finch_private)
    assert metadata.provider == :langsmith
    assert metadata.operation == :multipart
    assert metadata.method == :post
    assert metadata.project == "beam-weaver"
    assert metadata.run_count == 1
    assert metadata.post_count == 1
    assert metadata.patch_count == 0
    assert metadata.url == "https://api.smith.langchain.com/runs/multipart"

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
    assert String.ends_with?(url, "/runs/multipart")
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
    assert %{patch: [patch]} = payload
    assert patch.id =~ @uuid_regex
    assert patch.extra.metadata.beam_weaver_run_id == "run_stop"
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
    assert %{patch: [patch]} = payload
    assert patch.id =~ @uuid_regex
    assert patch.extra.metadata.beam_weaver_run_id == "persisted_1"
    assert [] = BeamWeaver.Tracing.Exporters.LangSmith.QueueStore.ETS.list(store, [])

    GenServer.stop(queue)
    Process.unregister(:langsmith_queue_test)
  end

  test "queue child spec uses a long shutdown budget for final trace flushes" do
    assert %{shutdown: 120_000} = Queue.child_spec([])
    assert %{shutdown: 30_000} = Queue.child_spec(shutdown: 30_000)
  end

  test "tracing flush_exporter drains configured LangSmith queue" do
    Process.register(self(), :langsmith_queue_test)

    {:ok, queue} =
      Queue.start_link(
        name: :langsmith_flush_exporter_queue,
        api_key: "test",
        project: "beam-weaver",
        transport: BeamWeaver.Tracing.LangSmithQueueTransport,
        flush_interval: 10_000
      )

    BeamWeaver.TestSupport.ConfigHelper.put_config(:tracing,
      exporter: Queue,
      exporter_opts: [queue: queue]
    )

    run =
      Run.new("flushable",
        id: "flushable_1",
        trace_id: "trace_flushable",
        kind: :graph,
        started_at: ~U[2026-05-22 00:00:00Z]
      )

    assert :ok = Queue.enqueue(queue, :ok, %{run | status: :ok, ended_at: ~U[2026-05-22 00:00:01Z]})
    assert :ok = Tracing.flush_exporter(5_000)

    assert_receive {:langsmith_post, _url, payload}
    assert %{patch: [patch]} = payload
    assert patch.extra.metadata.beam_weaver_run_id == "flushable_1"

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

    assert ids["run_model_event"].extra.invocation_params == %{
             _type: "openai-chat",
             model: "gpt-test",
             model_name: "gpt-test",
             temperature: 0.2
           }

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
      {:langsmith_post, url, BeamWeaver.Tracing.LangSmithTestTransport.payload(opts)}
    )

    {:ok, %{status: 202}}
  end

  def patch(url, opts) do
    post(url, opts)
  end
end

defmodule BeamWeaver.Tracing.LangSmithQueueOptionsTransport do
  def post(url, opts) do
    send(
      Process.whereis(:langsmith_queue_test),
      {:langsmith_post_opts, url, Keyword.take(opts, [:headers, :finch_private])}
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
    payload = BeamWeaver.Tracing.LangSmithTestTransport.payload(opts)

    if String.ends_with?(url, "/runs/multipart") or String.ends_with?(url, "/runs/batch") do
      send(Process.whereis(:langsmith_queue_test), {:langsmith_batch_attempt, payload})
      {:ok, %{status: 404}}
    else
      send(Process.whereis(:langsmith_queue_test), {:langsmith_individual_post, payload})
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

defmodule BeamWeaver.Tracing.LangSmithTestTransport do
  def payload(opts) do
    case Keyword.fetch(opts, :json) do
      {:ok, json} -> json
      :error -> multipart_payload(opts)
    end
  end

  defp multipart_payload(opts) do
    body = Keyword.fetch!(opts, :body)
    headers = Keyword.fetch!(opts, :headers)
    boundary = multipart_boundary!(headers)

    body
    |> String.split("--#{boundary}")
    |> Enum.map(&String.trim_leading(&1, "\r\n"))
    |> Enum.reject(&(&1 in ["", "--\r\n", "--"]))
    |> Enum.reduce({%{}, []}, fn part, {runs, order} ->
      [header, payload] = String.split(part, "\r\n\r\n", parts: 2)
      name = Regex.run(~r/name="([^"]+)"/, header) |> List.last()
      value = payload |> String.trim_trailing("\r\n") |> Jason.decode!(keys: :atoms)

      [operation, run_id | path] = String.split(name, ".")
      key = {String.to_atom(operation), run_id}

      runs =
        Map.update(runs, key, value, fn existing ->
          case path do
            [] -> Map.merge(existing, value)
            [field] -> Map.put(existing, String.to_atom(field), value)
          end
        end)

      order = if key in order, do: order, else: order ++ [key]
      {runs, order}
    end)
    |> then(fn {runs, order} ->
      order
      |> Enum.reduce(%{}, fn {operation, _run_id} = key, acc ->
        Map.update(acc, operation, [Map.fetch!(runs, key)], &(&1 ++ [Map.fetch!(runs, key)]))
      end)
    end)
  end

  defp multipart_boundary!(headers) do
    headers
    |> Enum.find_value(fn
      {"content-type", value} -> boundary_from_content_type(value)
      {"Content-Type", value} -> boundary_from_content_type(value)
      _other -> nil
    end)
  end

  defp boundary_from_content_type(value) do
    case Regex.run(~r/boundary=([^;]+)/, value) do
      [_, boundary] -> boundary
      _other -> nil
    end
  end
end

defmodule BeamWeaver.Tracing.LangSmithSlowTransport do
  def post(_url, _opts) do
    Process.sleep(50)
    {:ok, %{status: 202}}
  end

  def patch(url, opts), do: post(url, opts)
end
