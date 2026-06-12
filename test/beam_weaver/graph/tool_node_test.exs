defmodule BeamWeaver.Graph.ToolNodeTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Agent.ToolCallRequest
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Core.ToolResult
  alias BeamWeaver.Core.ToolRuntime
  alias BeamWeaver.Graph
  alias BeamWeaver.Graph.Command
  alias BeamWeaver.Graph.ExecutionInfo
  alias BeamWeaver.Graph.Messages
  alias BeamWeaver.Graph.Nodes.ToolNode
  alias BeamWeaver.Graph.Runtime
  alias BeamWeaver.Graph.Send

  defmodule ArgumentDoublerMiddleware do
    @behaviour BeamWeaver.Agent.Middleware

    def name(_middleware), do: :argument_doubler

    def wrap_tool_call(request, handler) do
      args =
        request.tool_call.args
        |> Map.update("a", nil, &(&1 * 2))
        |> Map.update("b", nil, &(&1 * 2))

      request
      |> ToolCallRequest.override(tool_call: %{request.tool_call | args: args})
      |> handler.()
    end
  end

  defmodule StateRecorderMiddleware do
    @behaviour BeamWeaver.Agent.Middleware

    def name(_middleware), do: :state_recorder

    def wrap_tool_call(request, handler) do
      case request.runtime do
        %{context: %{parent: parent}} when is_pid(parent) ->
          send(parent, {:tool_request_state, request.state})

        _other ->
          :ok
      end

      handler.(request)
    end
  end

  defmodule ThrowingToolMiddleware do
    @behaviour BeamWeaver.Agent.Middleware

    def name(_middleware), do: :throwing_tool_middleware

    def wrap_tool_call(_request, _handler) do
      raise ArgumentError, "middleware rejected tool call"
    end
  end

  defmodule NilToolMiddleware do
    @behaviour BeamWeaver.Agent.Middleware

    def name(_middleware), do: :nil_tool_middleware

    def wrap_tool_call(_request, _handler), do: nil
  end

  defmodule UnregisteredToolInterceptor do
    @behaviour BeamWeaver.Agent.Middleware

    def name(_middleware), do: :unregistered_tool_interceptor

    def wrap_tool_call(request, handler) do
      case request.tool_call.name do
        "magic_tool" ->
          Message.tool("magic:#{request.tool_call.args["value"]}",
            tool_call_id: request.tool_call.id,
            name: "magic_tool"
          )

        _other ->
          handler.(request)
      end
    end
  end

  test "executes tool calls from the last assistant message and returns tool messages" do
    weather =
      Tool.from_function!(
        name: "weather",
        description: "Get weather",
        input_schema: %{"required" => ["city"]},
        handler: fn %{"city" => city}, _opts -> "Weather in #{city}: sunny" end
      )

    node = ToolNode.new([weather])

    state = %{
      messages: [
        Message.user("weather?"),
        Message.assistant("",
          tool_calls: [
            %{"id" => "call-1", "name" => "weather", "args" => %{"city" => "Paris"}}
          ]
        )
      ]
    }

    assert %{messages: [tool_message]} = ToolNode.invoke(node, state)
    assert tool_message.role == :tool
    assert tool_message.name == "weather"
    assert tool_message.tool_call_id == "call-1"
    assert tool_message.content == "Weather in Paris: sunny"
    assert tool_message.metadata.status == "success"
  end

  test "accepts OpenAI-style function arguments encoded as JSON" do
    echo =
      Tool.from_function!(
        name: "echo",
        description: "Echo",
        input_schema: %{"required" => ["value"]},
        handler: fn %{"value" => value}, _opts -> %{echo: value} end
      )

    node = ToolNode.new([echo])

    assert [message] =
             ToolNode.invoke(node, [
               %{
                 "id" => "call-1",
                 "function" => %{"name" => "echo", "arguments" => ~s({"value":"ok"})}
               }
             ])

    assert message.content == ~s({"echo":"ok"})
    assert message.tool_call_id == "call-1"
  end

  test "serializes structured tool output without escaping UTF-8 text" do
    days = ["星期一", "水曜日", "목요일", "Friday"]

    get_days =
      Tool.from_function!(
        name: "get_days",
        description: "Get day names",
        input_schema: %{"required" => ["days"]},
        handler: fn %{"days" => days}, _opts -> days end
      )

    assert [message] =
             ToolNode.invoke(ToolNode.new([get_days]), [
               %{id: "call-days", name: "get_days", args: %{"days" => days}}
             ])

    assert message.content == ~s(["星期一","水曜日","목요일","Friday"])
    assert message.tool_call_id == "call-days"
  end

  test "exposes native registry and message-content helpers" do
    echo =
      Tool.from_function!(
        name: "echo",
        description: "Echo",
        input_schema: %{},
        handler: fn input, _opts -> input end
      )

    tools = ToolNode.tools_by_name([echo])
    assert Map.keys(tools) == ["echo"]

    node = ToolNode.new([echo])
    assert ToolNode.tools_by_name(node) == tools
    assert ToolNode.msg_content_output("already text") == "already text"

    assert ToolNode.msg_content_output(%{answer: "sí", count: 2}) |> BeamWeaver.JSON.decode!() ==
             %{
               "answer" => "sí",
               "count" => 2
             }

    assert ToolNode.msg_content_output([1, "two"]) == ~s([1,"two"])
    assert ToolNode.msg_content_output(42) == "42"
  end

  test "tool call requests are immutable and override only native request fields" do
    request = %ToolCallRequest{
      tool_call: %{id: "call-a", name: "echo", args: %{}},
      tool: :old_tool,
      tool_set: :tool_set,
      state: %{step: 1},
      runtime: %{context: :old}
    }

    updated =
      ToolCallRequest.override(request,
        tool_call: %{id: "call-b", name: "echo", args: %{"x" => 1}},
        state: %{step: 2},
        unknown: :ignored
      )

    assert updated.tool_call == %{id: "call-b", name: "echo", args: %{"x" => 1}}
    assert updated.state == %{step: 2}
    assert updated.tool == :old_tool
    assert updated.tool_set == :tool_set
    assert updated.runtime == %{context: :old}
    assert request.tool_call == %{id: "call-a", name: "echo", args: %{}}
    refute Map.has_key?(updated, :unknown)

    assert ToolCallRequest.override(request, %{"runtime" => %{context: :new}}).runtime == %{
             context: :new
           }
  end

  test "injects runtime-only tool arguments without requiring them from model args" do
    parent = self()

    inspect_runtime =
      Tool.from_function!(
        name: "inspect_runtime",
        description: "Uses injected runtime values",
        input_schema: %{
          type: "object",
          properties: %{
            query: %{type: "string"},
            state: %{type: "object"},
            store: %{type: "object"},
            runtime: %{type: "object"},
            tool_runtime: %{type: "object"},
            tool_call_id: %{type: "string"},
            context: %{type: "object"},
            config: %{type: "object"},
            checkpointer: %{type: "object"}
          },
          required: [
            :query,
            :state,
            :store,
            :runtime,
            :tool_runtime,
            :tool_call_id,
            :context,
            :config,
            :checkpointer
          ]
        },
        injected: [
          state: :state,
          store: :store,
          runtime: :runtime,
          tool_runtime: :tool_runtime,
          tool_call_id: :tool_call_id,
          context: :context,
          config: :config,
          checkpointer: :checkpointer
        ],
        handler: fn input, _opts ->
          send(parent, {:tool_input, input})
          "#{input["query"]}:#{input.tool_call_id}:#{input.context.user_id}"
        end
      )

    node = ToolNode.new([inspect_runtime])

    state = %{
      messages: [
        Message.assistant("",
          tool_calls: [
            %{id: "call-runtime", name: "inspect_runtime", args: %{"query" => "status"}}
          ]
        )
      ],
      user_visible: true
    }

    runtime = %Runtime{
      context: %{user_id: "user-123"},
      store: %{adapter: :ets},
      checkpointer: %{adapter: :memory},
      config: %{trace: true}
    }

    assert %{messages: [message]} = ToolNode.invoke(node, state, runtime)
    assert message.content == "status:call-runtime:user-123"
    assert message.metadata.status == "success"

    assert_receive {:tool_input, input}
    assert input["query"] == "status"
    assert input.state == state
    assert input.store == runtime.store
    assert input.runtime == runtime
    assert %ToolRuntime{} = input.tool_runtime
    assert input.tool_runtime.tool_name == "inspect_runtime"
    assert input.tool_runtime.tool_call_id == "call-runtime"
    assert input.tool_runtime.args == %{"query" => "status"}
    assert input.tool_runtime.state == state
    assert input.tool_runtime.runtime == runtime
    assert input.tool_runtime.context == runtime.context
    assert input.tool_runtime.store == runtime.store
    assert input.tool_runtime.config == runtime.config
    assert input.tool_call_id == "call-runtime"
    assert input.context == runtime.context
    assert input.config == runtime.config
    assert input.checkpointer == runtime.checkpointer
  end

  test "injects selected state fields and uses nil for absent optional fields" do
    parent = self()

    weather =
      Tool.from_function!(
        name: "weather",
        description: "Uses selected graph state",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "query" => %{"type" => "string"},
            "city" => %{"type" => ["string", "null"]},
            "tenant" => %{"type" => ["string", "null"]}
          },
          "required" => ["query", "city", "tenant"]
        },
        injected: %{
          "city" => {:state, :city},
          "tenant" => {:state, [:profile, :tenant]}
        },
        handler: fn input, _opts ->
          send(parent, {:selected_state_input, input})
          "#{input["query"]}:#{inspect(input["city"])}:#{inspect(input["tenant"])}"
        end
      )

    node = ToolNode.new([weather])

    missing_state = %{
      messages: [
        Message.assistant("",
          tool_calls: [
            %{id: "call-missing-city", name: "weather", args: %{"query" => "forecast"}}
          ]
        )
      ]
    }

    assert %{messages: [missing]} = ToolNode.invoke(node, missing_state)
    assert missing.content == ~s(forecast:nil:nil)
    assert missing.metadata.status == "success"

    assert_receive {:selected_state_input, %{"query" => "forecast", "city" => nil, "tenant" => nil}}

    present_state = %{
      "messages" => [
        Message.assistant("",
          tool_calls: [
            %{id: "call-present-city", name: "weather", args: %{"query" => "forecast"}}
          ]
        )
      ],
      "city" => "Nicosia",
      profile: %{"tenant" => "cy"}
    }

    assert %{"messages" => [present]} = ToolNode.invoke(node, present_state)
    assert present.content == ~s(forecast:"Nicosia":"cy")

    assert_receive {:selected_state_input, %{"query" => "forecast", "city" => "Nicosia", "tenant" => "cy"}}
  end

  test "tool runtime forwards execution info server info and available tools" do
    parent = self()

    inspect_runtime =
      Tool.from_function!(
        name: "inspect_runtime",
        description: "Inspects runtime metadata",
        input_schema: %{
          type: "object",
          properties: %{tool_runtime: %{type: "object"}},
          required: [:tool_runtime]
        },
        injected: [tool_runtime: :tool_runtime],
        handler: fn input, _opts ->
          send(parent, {:tool_runtime, input.tool_runtime})
          "ok"
        end
      )

    other =
      Tool.from_function!(
        name: "other",
        description: "Other tool",
        input_schema: %{},
        handler: fn _input, _opts -> "other" end
      )

    execution = %ExecutionInfo{
      thread_id: "thread-1",
      checkpoint_id: "checkpoint-1",
      checkpoint_ns: "node:task",
      task_id: "task-1",
      run_id: "run-1"
    }

    runtime = %Runtime{
      execution: execution,
      server_info: %{assistant_id: "assistant-1", graph_id: "graph-1"}
    }

    assert [message] =
             ToolNode.invoke(
               ToolNode.new([inspect_runtime, other]),
               [%{id: "call-runtime", name: "inspect_runtime", args: %{}}],
               runtime
             )

    assert message.content == "ok"

    assert_receive {:tool_runtime, %ToolRuntime{} = tool_runtime}
    assert tool_runtime.execution_info == execution
    assert tool_runtime.server_info == %{assistant_id: "assistant-1", graph_id: "graph-1"}

    assert tool_runtime.tools |> Enum.map(&Tool.name/1) |> Enum.sort() == [
             "inspect_runtime",
             "other"
           ]

    assert ToolRuntime.new([]).tools == []
  end

  test "converts unknown tools and validation failures into tool error messages by default" do
    weather =
      Tool.from_function!(
        name: "weather",
        description: "Get weather",
        input_schema: %{"required" => ["city"]},
        handler: fn _input, _opts -> "sunny" end
      )

    node = ToolNode.new([weather])

    assert [unknown, invalid] =
             ToolNode.invoke(node, [
               %{id: "missing", name: "missing_tool", args: %{}},
               %{id: "invalid", name: "weather", args: %{}}
             ])

    assert unknown.metadata.status == "error"
    assert unknown.content =~ "tool is not registered"
    assert invalid.metadata.status == "error"
    assert invalid.content =~ "missing required keys"
  end

  test "wrap_tool_call can handle unregistered tools without executing the static registry" do
    # Upstream reference:
    registered =
      Tool.from_function!(
        name: "registered",
        description: "Registered",
        input_schema: %{"required" => ["x"]},
        handler: fn %{"x" => x}, _opts -> "registered:#{x}" end
      )

    node = ToolNode.new([registered], wrap_tool_call: [UnregisteredToolInterceptor])

    assert [registered_message, magic_message] =
             ToolNode.invoke(node, [
               %{id: "call-registered", name: "registered", args: %{"x" => 7}},
               %{id: "call-magic", name: "magic_tool", args: %{"value" => 21}}
             ])

    assert registered_message.content == "registered:7"
    assert registered_message.tool_call_id == "call-registered"
    assert magic_message.content == "magic:21"
    assert magic_message.name == "magic_tool"
    assert magic_message.tool_call_id == "call-magic"
  end

  test "wrap_tool_call can override arguments and capture middleware exceptions as tool errors" do
    add =
      Tool.from_function!(
        name: "add",
        description: "Add numbers",
        input_schema: %{"required" => ["a", "b"]},
        handler: fn %{"a" => a, "b" => b}, _opts -> a + b end
      )

    assert [message] =
             ToolNode.invoke(
               ToolNode.new([add], wrap_tool_call: [ArgumentDoublerMiddleware]),
               [%{id: "call-double", name: "add", args: %{"a" => 1, "b" => 2}}]
             )

    assert message.content == "6"
    assert message.tool_call_id == "call-double"

    assert [error] =
             ToolNode.invoke(
               ToolNode.new([add], wrap_tool_call: [ThrowingToolMiddleware]),
               [%{id: "call-error", name: "add", args: %{"a" => 1, "b" => 2}}]
             )

    assert error.metadata.status == "error"
    assert error.metadata.error_type == :tool_middleware_exception
    assert error.content =~ "middleware rejected tool call"

    assert [invalid] =
             ToolNode.invoke(
               ToolNode.new([add], wrap_tool_call: [NilToolMiddleware]),
               [%{id: "call-nil", name: "add", args: %{"a" => 1, "b" => 2}}]
             )

    assert invalid.metadata.status == "error"
    assert invalid.metadata.error_type == :invalid_tool_middleware_result
    assert invalid.content =~ "invalid result"
  end

  test "wrap_tool_call receives graph state for tool-call context wrappers and raw sends" do
    add =
      Tool.from_function!(
        name: "add",
        description: "Add numbers",
        input_schema: %{"required" => ["a", "b"]},
        handler: fn %{"a" => a, "b" => b}, _opts -> a + b end
      )

    runtime = %Runtime{context: %{parent: self()}}

    wrapper_state = %{
      messages: [Message.assistant("from wrapper")],
      files: %{"/a.md" => "body"}
    }

    assert [message] =
             ToolNode.invoke(
               ToolNode.new([add], wrap_tool_call: [StateRecorderMiddleware]),
               %{
                 "__type" => "tool_call_with_context",
                 "tool_call" => %{
                   "id" => "call-wrapper",
                   "name" => "add",
                   "args" => %{"a" => 1, "b" => 2}
                 },
                 "state" => wrapper_state
               },
               runtime
             )

    assert message.content == "3"
    assert_receive {:tool_request_state, ^wrapper_state}

    previous_state = %{messages: [Message.assistant("from channels")], files: %{}}
    runtime = %Runtime{context: %{parent: self()}, previous_state: previous_state}

    assert [message] =
             ToolNode.invoke(
               ToolNode.new([add], wrap_tool_call: [StateRecorderMiddleware]),
               [%{id: "call-send", name: "add", args: %{"a" => 2, "b" => 3}}],
               runtime
             )

    assert message.content == "5"
    assert_receive {:tool_request_state, ^previous_state}
  end

  test "turns schema type errors into tool messages without executing the tool" do
    parent = self()

    select_number =
      Tool.from_function!(
        name: "select_number",
        description: "Select a number",
        input_schema: %{
          "required" => ["value"],
          "properties" => %{"value" => %{"type" => "integer"}}
        },
        handler: fn input, _opts ->
          send(parent, {:executed, input})
          "selected #{input["value"]}"
        end
      )

    node = ToolNode.new([select_number])

    assert [message] =
             ToolNode.invoke(node, [
               %{id: "invalid-type", name: "select_number", args: %{"value" => "nope"}}
             ])

    assert message.role == :tool
    assert message.tool_call_id == "invalid-type"
    assert message.metadata.status == "error"
    assert message.metadata.error_type == :invalid_input
    assert message.content =~ "invalid type"

    refute_receive {:executed, _input}
  end

  test "validation error messages include model args but filter injected runtime values" do
    # Upstream reference:
    parent = self()

    private_search =
      Tool.from_function!(
        name: "private_search",
        description: "Search with injected state and runtime",
        input_schema: %{
          "type" => "object",
          "required" => ["query", "limit", "state", "store", "runtime"],
          "properties" => %{
            "query" => %{"type" => "string"},
            "limit" => %{"type" => "integer"},
            "state" => %{"type" => "object"},
            "store" => %{"type" => "object"},
            "runtime" => %{"type" => "object"}
          }
        },
        injected: %{"state" => :state, "store" => :store, "runtime" => :runtime},
        handler: fn input, _opts ->
          send(parent, {:private_search_executed, input})
          "never"
        end
      )

    node = ToolNode.new([private_search])

    state = %{
      messages: [
        Message.assistant("",
          tool_calls: [
            %{
              id: "call-private-search",
              name: "private_search",
              args: %{"query" => 12_345, "state" => "model supplied but hidden"}
            }
          ]
        )
      ],
      secret_data: "sensitive_secret_123"
    }

    runtime = %Runtime{context: %{user_id: "user-123"}, store: %{token: "store-secret"}}

    assert %{messages: [message]} = ToolNode.invoke(node, state, runtime)

    assert message.role == :tool
    assert message.tool_call_id == "call-private-search"
    assert message.metadata.status == "error"

    assert message.content =~ "query"
    assert message.content =~ "12345"
    assert message.content =~ "limit"
    refute message.content =~ "state"
    refute message.content =~ "store"
    refute message.content =~ "runtime"
    refute message.content =~ "sensitive_secret_123"
    refute message.content =~ "store-secret"
    refute_receive {:private_search_executed, _input}, 50
  end

  test "keeps tool artifacts in metadata while returning model-visible content" do
    lookup =
      Tool.from_function!(
        name: "lookup",
        description: "Looks up a record",
        input_schema: %{"required" => ["id"]},
        handler: fn %{"id" => id}, _opts ->
          ToolResult.success("record #{id}",
            artifact: %{id: id, raw: %{score: 10}},
            metadata: %{source: "fixtures"}
          )
        end
      )

    tuple_lookup =
      Tool.from_function!(
        name: "tuple_lookup",
        description: "Looks up a tuple record",
        input_schema: %{},
        handler: fn _input, _opts ->
          {:content_and_artifact, %{answer: 42}, %{raw: [42]}}
        end
      )

    node = ToolNode.new([lookup, tuple_lookup])

    assert [record, tuple_record] =
             ToolNode.invoke(node, [
               %{id: "call-record", name: "lookup", args: %{"id" => "a1"}},
               %{id: "call-tuple", name: "tuple_lookup", args: %{}}
             ])

    assert record.content == "record a1"
    assert record.metadata.status == "success"
    assert record.metadata.source == "fixtures"
    assert record.metadata.artifact == %{id: "a1", raw: %{score: 10}}

    assert tuple_record.content == ~s({"answer":42})
    assert tuple_record.metadata.status == "success"
    assert tuple_record.metadata.artifact == %{raw: [42]}
  end

  test "lets tool commands update state and route the graph when a matching tool message is returned" do
    route =
      Tool.from_function!(
        name: "route",
        description: "Routes after a tool",
        input_schema: %{
          type: "object",
          properties: %{route: %{type: "string"}, tool_call_id: %{type: "string"}},
          required: [:route, :tool_call_id]
        },
        injected: [tool_call_id: :tool_call_id],
        handler: fn input, _opts ->
          %Command{
            update: %{
              route: input["route"],
              messages: [Message.tool("routed", tool_call_id: input.tool_call_id)]
            },
            goto: :after_tool
          }
        end
      )

    graph =
      Graph.new()
      |> Graph.add_reducer(:messages, fn existing, update -> existing ++ List.wrap(update) end)
      |> Graph.add_node(:tools, ToolNode.new([route]))
      |> Graph.add_node(:after_tool, fn state ->
        %{
          routed: state.route,
          tool_message_count: Enum.count(state.messages, &(&1.role == :tool))
        }
      end)
      |> Graph.add_edge(Graph.start(), :tools)
      |> Graph.add_edge(:after_tool, Graph.end_node())
      |> Graph.compile!()

    assert {:ok, state} =
             BeamWeaver.Graph.Compiled.invoke(graph, %{
               messages: [
                 Message.assistant("",
                   tool_calls: [
                     %{id: "call-route", name: "route", args: %{"route" => "approved"}}
                   ]
                 )
               ]
             })

    assert state.routed == "approved"
    assert state.tool_message_count == 1
    assert List.last(state.messages).content == "routed"
    assert List.last(state.messages).tool_call_id == "call-route"
  end

  test "merges multiple command-returning tool calls deterministically" do
    first =
      Tool.from_function!(
        name: "first",
        description: "First command",
        input_schema: %{required: [:tool_call_id]},
        injected: [tool_call_id: :tool_call_id],
        handler: fn input, _opts ->
          %Command{
            update: %{
              first: true,
              messages: [Message.tool("first done", tool_call_id: input.tool_call_id)]
            },
            goto: :first_next
          }
        end
      )

    second =
      Tool.from_function!(
        name: "second",
        description: "Second command",
        input_schema: %{required: [:tool_call_id]},
        injected: [tool_call_id: :tool_call_id],
        handler: fn input, _opts ->
          %Command{
            update: %{
              second: true,
              messages: [Message.tool("second done", tool_call_id: input.tool_call_id)]
            },
            goto: :second_next
          }
        end
      )

    node = ToolNode.new([first, second])

    assert %Command{update: update, goto: [:first_next, :second_next]} =
             ToolNode.invoke(node, [
               %{id: "call-first", name: "first", args: %{}},
               %{id: "call-second", name: "second", args: %{}}
             ])

    assert update.first
    assert update.second
    assert Enum.map(update.messages, & &1.content) == ["first done", "second done"]
    assert Enum.map(update.messages, & &1.tool_call_id) == ["call-first", "call-second"]
  end

  test "merges sibling map updates from concurrent command-returning tool calls" do
    first =
      Tool.from_function!(
        name: "first",
        description: "First command",
        input_schema: %{required: [:tool_call_id]},
        injected: [tool_call_id: :tool_call_id],
        handler: fn input, _opts ->
          %Command{
            update: %{
              subagent_outputs: %{"first_output" => %{"answer" => "first"}},
              subagent_cache: %{"first:hash" => %{"output" => %{"answer" => "first"}}},
              messages: [Message.tool("first captured", tool_call_id: input.tool_call_id)]
            }
          }
        end
      )

    second =
      Tool.from_function!(
        name: "second",
        description: "Second command",
        input_schema: %{required: [:tool_call_id]},
        injected: [tool_call_id: :tool_call_id],
        handler: fn input, _opts ->
          %Command{
            update: %{
              subagent_outputs: %{"second_output" => %{"answer" => "second"}},
              subagent_cache: %{"second:hash" => %{"output" => %{"answer" => "second"}}},
              messages: [Message.tool("second captured", tool_call_id: input.tool_call_id)]
            }
          }
        end
      )

    assert %Command{update: update} =
             ToolNode.invoke(ToolNode.new([first, second]), [
               %{id: "call-first", name: "first", args: %{}},
               %{id: "call-second", name: "second", args: %{}}
             ])

    assert update.subagent_outputs == %{
             "first_output" => %{"answer" => "first"},
             "second_output" => %{"answer" => "second"}
           }

    assert update.subagent_cache |> Map.keys() |> Enum.sort() == ["first:hash", "second:hash"]
    assert Enum.map(update.messages, & &1.content) == ["first captured", "second captured"]
  end

  test "tool command can remove all messages without a matching tool terminator" do
    clear =
      Tool.from_function!(
        name: "clear",
        description: "Clears conversation messages",
        input_schema: %{},
        handler: fn _input, _opts ->
          %Command{update: %{messages: [Messages.remove_all()]}}
        end
      )

    assert %Command{update: %{messages: [%Messages.Remove{} = remove]}} =
             ToolNode.invoke(ToolNode.new([clear]), [
               %{id: "call-clear", name: "clear", args: %{}}
             ])

    assert remove == Messages.remove_all()
  end

  test "parent graph tool commands can fan out with sends" do
    transfer =
      Tool.from_function!(
        name: "transfer",
        description: "Transfers work to two parent nodes",
        input_schema: %{required: [:tool_call_id]},
        injected: [tool_call_id: :tool_call_id],
        handler: fn input, _opts ->
          %Command{
            graph: Command.parent(),
            goto: [
              %Send{
                node: :alice,
                update: %{messages: [Message.tool("alice", tool_call_id: input.tool_call_id)]}
              },
              %Send{
                node: :bob,
                update: %{messages: [Message.tool("bob", tool_call_id: input.tool_call_id)]}
              }
            ]
          }
        end
      )

    assert %Command{graph: :parent, goto: [%Send{node: :alice}, %Send{node: :bob}]} =
             ToolNode.invoke(ToolNode.new([transfer]), [
               %{id: "call-transfer", name: "transfer", args: %{}}
             ])
  end

  test "merges mixed command and message outputs from one tool call" do
    mixed =
      Tool.from_function!(
        name: "mixed",
        description: "Returns a command plus a tool message",
        input_schema: %{required: [:tool_call_id]},
        injected: [tool_call_id: :tool_call_id],
        handler: fn input, _opts ->
          [
            %Command{update: %{flag: true}, goto: :next},
            Message.tool("mixed done", tool_call_id: input.tool_call_id)
          ]
        end
      )

    node = ToolNode.new([mixed])

    assert %Command{update: update, goto: :next} =
             ToolNode.invoke(node, [%{id: "call-mixed", name: "mixed", args: %{}}])

    assert update.flag
    assert [%Message{content: "mixed done", tool_call_id: "call-mixed"}] = update.messages
  end

  test "tool commands can target the parent graph from a subgraph" do
    escalate =
      Tool.from_function!(
        name: "escalate",
        description: "Escalates to the parent graph",
        input_schema: %{required: [:tool_call_id]},
        injected: [tool_call_id: :tool_call_id],
        handler: fn input, _opts ->
          %Command{
            graph: Command.parent(),
            update: %{
              escalated: true,
              messages: [Message.tool("escalated", tool_call_id: input.tool_call_id)]
            },
            goto: :after_tool
          }
        end
      )

    child =
      Graph.new(name: "child")
      |> Graph.add_reducer(:messages, fn existing, update -> existing ++ List.wrap(update) end)
      |> Graph.add_node(:tools, ToolNode.new([escalate]))
      |> Graph.add_edge(Graph.start(), :tools)
      |> Graph.add_edge(:tools, Graph.end_node())
      |> Graph.compile!()

    parent =
      Graph.new(name: "parent")
      |> Graph.add_reducer(:messages, fn existing, update -> existing ++ List.wrap(update) end)
      |> Graph.add_node(:child, child)
      |> Graph.add_node(:after_tool, fn state ->
        %{
          after_tool: state.escalated,
          tool_messages: Enum.count(state.messages, &(&1.role == :tool))
        }
      end)
      |> Graph.add_edge(Graph.start(), :child)
      |> Graph.add_edge(:after_tool, Graph.end_node())
      |> Graph.compile!()

    assert {:ok, state} =
             BeamWeaver.Graph.Compiled.invoke(parent, %{
               messages: [
                 Message.assistant("",
                   tool_calls: [
                     %{id: "call-escalate", name: "escalate", args: %{}}
                   ]
                 )
               ]
             })

    assert state.after_tool
    assert state.tool_messages == 1
    assert List.last(state.messages).content == "escalated"
    assert List.last(state.messages).tool_call_id == "call-escalate"
  end

  test "converts current-graph tool commands without matching tool messages into tool errors" do
    command_without_message =
      Tool.from_function!(
        name: "bad_command",
        description: "Returns an invalid command",
        input_schema: %{},
        handler: fn _input, _opts -> %Command{update: %{flag: true}, goto: :next} end
      )

    node = ToolNode.new([command_without_message])

    assert [message] =
             ToolNode.invoke(node, [
               %{id: "call-bad", name: "bad_command", args: %{}}
             ])

    assert message.role == :tool
    assert message.metadata.status == "error"
    assert message.metadata.error_type == :invalid_tool_command
    assert message.content =~ "matching tool message"
    assert message.tool_call_id == "call-bad"
  end

  test "can return an error instead of tool messages when error handling is disabled" do
    node = ToolNode.new([], handle_errors: false)

    assert {:error, %{type: :unknown_tool}} =
             ToolNode.invoke(node, [%{id: "missing", name: "missing_tool", args: %{}}])
  end

  test "can handle only selected BeamWeaver error types" do
    weather =
      Tool.from_function!(
        name: "weather",
        description: "Get weather",
        input_schema: %{"required" => ["city"]},
        handler: fn _input, _opts -> "sunny" end
      )

    node = ToolNode.new([weather], handle_errors: [:invalid_input])

    assert [message] = ToolNode.invoke(node, [%{id: "invalid", name: "weather", args: %{}}])
    assert message.metadata.status == "error"
    assert message.metadata.error_type == :invalid_input

    assert {:error, %{type: :unknown_tool, details: %{tool: "missing_tool"}}} =
             ToolNode.invoke(node, [%{id: "missing", name: "missing_tool", args: %{}}])
  end

  test "consecutive concurrent tools run together and preserve output order" do
    parent = self()
    first = blocking_tool("first", parent)
    second = blocking_tool("second", parent)
    node = ToolNode.new([first, second], timeout: 1_000)

    task =
      Task.async(fn ->
        ToolNode.invoke(node, [
          %{id: "call-1", name: "first", args: %{}},
          %{id: "call-2", name: "second", args: %{}}
        ])
      end)

    assert_receive {:started, "first", first_pid}, 500
    assert_receive {:started, "second", second_pid}, 500

    send(first_pid, :release)
    send(second_pid, :release)

    assert [
             %Message{name: "first", content: "first"},
             %Message{name: "second", content: "second"}
           ] =
             Task.await(task, 1_000)
  end

  test "concurrent tools use the runtime task supervisor when present" do
    parent = self()
    {:ok, supervisor} = Task.Supervisor.start_link()

    supervised = blocking_tool("supervised", parent)
    node = ToolNode.new([supervised], timeout: 1_000)
    runtime = %Runtime{execution: %{task_supervisor: supervisor}}

    task =
      Task.async(fn ->
        ToolNode.invoke(
          node,
          [%{id: "call-supervised", name: "supervised", args: %{}}],
          runtime
        )
      end)

    assert_receive {:started, "supervised", tool_pid}, 500
    assert tool_pid in Task.Supervisor.children(supervisor)

    send(tool_pid, :release)

    assert [%Message{name: "supervised", content: "supervised"}] = Task.await(task, 1_000)
  end

  test "non-concurrent tools create ordering barriers" do
    parent = self()
    first = blocking_tool("first", parent)
    barrier = blocking_tool("barrier", parent, concurrent: false)
    second = blocking_tool("second", parent)
    node = ToolNode.new([first, barrier, second], timeout: 1_000)

    task =
      Task.async(fn ->
        ToolNode.invoke(node, [
          %{id: "call-1", name: "first", args: %{}},
          %{id: "call-2", name: "barrier", args: %{}},
          %{id: "call-3", name: "second", args: %{}}
        ])
      end)

    assert_receive {:started, "first", first_pid}, 500
    refute_received {:started, "barrier", _pid}
    refute_received {:started, "second", _pid}

    send(first_pid, :release)

    assert_receive {:started, "barrier", barrier_pid}, 500
    refute_received {:started, "second", _pid}

    send(barrier_pid, :release)

    assert_receive {:started, "second", second_pid}, 500
    send(second_pid, :release)

    assert [
             %Message{name: "first", content: "first"},
             %Message{name: "barrier", content: "barrier"},
             %Message{name: "second", content: "second"}
           ] = Task.await(task, 1_000)
  end

  test "max_result_chars truncates only model-visible tool message text" do
    long =
      Tool.from_function!(
        name: "long",
        description: "Long result",
        input_schema: %{},
        max_result_chars: 32,
        handler: fn _input, _opts -> String.duplicate("x", 100) end
      )

    node = ToolNode.new([long])

    assert [%Message{content: content}] =
             ToolNode.invoke(node, [%{id: "call-long", name: "long", args: %{}}])

    assert String.length(content) <= 32
    assert content =~ "truncated"
  end

  test "returns structured tool timeout messages by default" do
    slow =
      Tool.from_function!(
        name: "slow",
        description: "Slow tool",
        input_schema: %{},
        handler: fn _input, _opts ->
          Process.sleep(100)
          "late"
        end
      )

    node = ToolNode.new([slow], timeout: 10)

    assert [message] = ToolNode.invoke(node, [%{id: "call-slow", name: "slow", args: %{}}])
    assert message.role == :tool
    assert message.name == "slow"
    assert message.tool_call_id == "call-slow"
    assert message.metadata.status == "error"
    assert message.metadata.error_type == :tool_timeout
    assert message.content =~ "tool timed out"
  end

  test "returns timeout errors when tool error handling is disabled" do
    slow =
      Tool.from_function!(
        name: "slow",
        description: "Slow tool",
        input_schema: %{},
        handler: fn _input, _opts ->
          Process.sleep(100)
          "late"
        end
      )

    node = ToolNode.new([slow], timeout: 10, handle_errors: false)

    assert {:error,
            %{
              type: :tool_timeout,
              message: "tool timed out",
              details: %{tool: "slow", tool_call_id: "call-slow", timeout: 10}
            }} = ToolNode.invoke(node, [%{id: "call-slow", name: "slow", args: %{}}])
  end

  test "tools_condition routes to tools only when tool calls are present" do
    assert ToolNode.tools_condition([Message.assistant("", tool_calls: [%{name: "a"}])]) == :tools
    assert ToolNode.tools_condition([Message.assistant("done")]) == :end
  end

  test "supports custom messages keys for subgraph state channels" do
    add =
      Tool.from_function!(
        name: "add",
        description: "Add",
        input_schema: %{"required" => ["a", "b"]},
        handler: fn %{"a" => a, "b" => b}, _opts -> a + b end
      )

    state = %{
      subgraph_messages: [
        Message.user("hi"),
        Message.assistant("",
          tool_calls: [%{id: "call-add", name: "add", args: %{"a" => 1, "b" => 2}}]
        )
      ]
    }

    node = ToolNode.new([add], messages_key: :subgraph_messages)

    assert ToolNode.tools_condition(state, :subgraph_messages) == :tools
    assert %{subgraph_messages: [message]} = ToolNode.invoke(node, state)
    assert message.role == :tool
    assert message.name == "add"
    assert message.tool_call_id == "call-add"
    assert message.content == "3"
  end

  test "runs as a graph node struct" do
    add =
      Tool.from_function!(
        name: "add",
        description: "Add",
        input_schema: %{"required" => ["a", "b"]},
        handler: fn %{"a" => a, "b" => b}, _opts -> a + b end
      )

    graph =
      Graph.new()
      |> Graph.add_node(:tools, ToolNode.new([add]))
      |> Graph.add_edge(Graph.start(), :tools)
      |> Graph.add_edge(:tools, Graph.end_node())

    compiled = Graph.compile!(graph)

    assert {:ok, %{messages: [message]}} =
             BeamWeaver.Graph.Compiled.invoke(compiled, %{
               messages: [
                 Message.assistant("",
                   tool_calls: [
                     %{id: "call-add", name: "add", args: %{"a" => 2, "b" => 3}}
                   ]
                 )
               ]
             })

    assert message.content == "5"
  end

  defp blocking_tool(name, parent, opts \\ []) do
    Tool.from_function!(
      [
        name: name,
        description: "Blocking #{name}",
        input_schema: %{},
        handler: fn _input, _opts ->
          send(parent, {:started, name, self()})

          receive do
            :release -> name
          after
            1_000 -> "timeout"
          end
        end
      ] ++ opts
    )
  end
end
