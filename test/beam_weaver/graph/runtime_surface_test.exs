defmodule BeamWeaver.Graph.RuntimeSurfaceTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Cache
  alias BeamWeaver.CachePolicy
  alias BeamWeaver.Checkpoint.ETS, as: CheckpointETS
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Tool
  alias BeamWeaver.ExecutionPolicy
  alias BeamWeaver.Graph
  alias BeamWeaver.Graph.Command
  alias BeamWeaver.Graph.Compiled
  alias BeamWeaver.Graph.Runtime
  alias BeamWeaver.Graph.ServerInfo
  alias BeamWeaver.Models.FakeChatModel
  alias BeamWeaver.RetryPolicy
  alias BeamWeaver.Runnable

  defmodule RuntimeStructNode do
    defstruct [:caller]

    def invoke(%__MODULE__{caller: caller}, state, runtime) do
      send(caller, {
        :runtime_seen,
        %{
          context: runtime.context,
          config: runtime.config,
          graph_name: runtime.graph_name,
          node: runtime.node,
          step: runtime.step,
          task_id?: is_binary(runtime.task_id),
          namespace: runtime.namespace,
          previous_state: runtime.previous_state,
          checkpoint: runtime.checkpoint,
          execution: runtime.execution,
          server_info: runtime.server_info
        }
      })

      %{seen: state.value + runtime.step}
    end
  end

  defmodule ModuleNode do
    def invoke(state, runtime) do
      %{module_node: "#{state.value}:#{runtime.node}"}
    end
  end

  test "destinations are introspection-only conditional edges with optional labels" do
    # Translates LangGraph test_pregel.py::test_node_destinations.
    for {destinations, expected_data} <- [
          {[:node_b, :node_c], %{"node_b" => nil, "node_c" => nil}},
          {%{node_b: "foo", node_c: "bar"}, %{"node_b" => "foo", "node_c" => "bar"}}
        ] do
      graph =
        Graph.new()
        |> Graph.add_node(
          :child,
          fn state ->
            %Command{update: %{foo: state.foo <> " child"}, goto: :node_c}
          end,
          destinations: destinations
        )
        |> Graph.add_node(:node_b, fn state -> %{foo: state.foo <> " b"} end)
        |> Graph.add_node(:node_c, fn state -> %{foo: state.foo <> " c"} end)
        |> Graph.add_edge(Graph.start(), :child)
        |> Graph.add_edge(:node_b, Graph.end_node())
        |> Graph.add_edge(:node_c, Graph.end_node())
        |> Graph.compile!()

      assert {:ok, %{foo: "start child c"}} = Compiled.invoke(graph, %{foo: "start"})

      destination_edges =
        graph
        |> Compiled.get_graph()
        |> Map.fetch!(:edges)
        |> Enum.filter(&(&1.source == "child" and &1.kind == :destination))
        |> Map.new(&{&1.target, &1.data})

      assert destination_edges == expected_data
    end
  end

  test "guarded edges can inspect source output and route through dependent work" do
    parent = self()

    graph =
      Graph.new()
      |> Graph.add_node(:route, fn state -> Map.put(state, :routed, true) end)
      |> Graph.add_node(:selected, fn _state -> %{selected: true} end)
      |> Graph.add_node(:after_branch, fn state -> %{done: state.selected} end, deps: :selected)
      |> Graph.add_edge(
        :route,
        :selected,
        when: fn output, state ->
          send(parent, {:route_input, output, state})
          output.routed == true
        end
      )
      |> Graph.add_edge(Graph.start(), :route)
      |> Graph.add_edge(:after_branch, Graph.end_node())
      |> Graph.compile!()

    assert {:ok, %{done: true}} = Compiled.invoke(graph, %{})
    assert_receive {:route_input, %{routed: true}, %{routed: true}}
  end

  test "validation rejects duplicate declarations, reserved names, and missing guarded targets" do
    # Translates graph-builder validation failures from LangGraph StateGraph tests.
    duplicate =
      Graph.new()
      |> Graph.add_node(:a, fn state -> state end)
      |> Graph.add_node(:a, fn state -> state end)
      |> Graph.add_edge(Graph.start(), :a)

    assert {:error, %Error{type: :invalid_graph, message: "graph contains duplicate declarations"}} =
             Graph.compile(duplicate)

    reserved =
      Graph.new()
      |> Graph.add_node("__interrupt__", fn state -> state end)
      |> Graph.add_edge(Graph.start(), "__interrupt__")

    assert {:error, %Error{type: :invalid_graph, message: "graph uses reserved node or channel names"}} =
             Graph.compile(reserved)

    missing_branch =
      Graph.new()
      |> Graph.add_node(:route, fn state -> state end)
      |> Graph.add_edge(:route, :missing, when: fn _output -> true end)
      |> Graph.add_edge(Graph.start(), :route)

    assert {:error, %Error{type: :invalid_graph, message: "graph references missing nodes"}} =
             Graph.compile(missing_branch)

    missing_dep =
      Graph.new()
      |> Graph.add_node(:start, fn state -> state end)
      |> Graph.add_node(:join, fn state -> state end, deps: [:missing_dep])
      |> Graph.add_edge(Graph.start(), :start)

    assert {:error, %Error{type: :invalid_graph, message: "graph references missing nodes"}} =
             Graph.compile(missing_dep)
  end

  test "validation report accumulates graph diagnostics while compile preserves first error" do
    # BeamWeaver-specific diagnostic hardening: public compile remains tagged and
    # first-error compatible, while tools can present all static problems.
    graph =
      Graph.new()
      |> Graph.add_node(:a, :not_a_node)
      |> Graph.add_node(:a, :not_a_node_again)
      |> Graph.add_node("__tasks__bad", fn state -> state end)
      |> Graph.add_edge(:a, :missing)
      |> Graph.add_node(:join, fn state -> state end, deps: [:missing_dep])
      |> Graph.add_edge(Graph.start(), :a)

    assert {:error, %Error{message: "graph contains duplicate declarations", details: %{duplicates: _}}} =
             Graph.compile(graph)

    report = Graph.validation_report(graph)
    messages = Enum.map(report.diagnostics, & &1.message)

    assert "graph contains duplicate declarations" in messages
    assert "graph references missing nodes" in messages
    assert "graph contains invalid node callables" in messages
    assert "graph uses reserved node or channel names" in messages

    missing = Enum.find(report.diagnostics, &(&1.message == "graph references missing nodes"))
    assert missing.details.missing == ["missing", "missing_dep"]
  end

  test "static validation rejects reachable dead ends without blocking dynamic graphs by default" do
    # Translates LangGraph dead-end validation while preserving BeamWeaver's dynamic Send/Command escape hatch.
    graph =
      Graph.new()
      |> Graph.add_node(:begin, fn state -> state end)
      |> Graph.add_node(:dead, fn state -> state end)
      |> Graph.add_node(:finish, fn state -> state end)
      |> Graph.add_edge(:begin, :dead)
      |> Graph.add_edge(:begin, :finish)
      |> Graph.add_edge(Graph.start(), :begin)
      |> Graph.add_edge(:finish, Graph.end_node())

    assert {:ok, _compiled} = Graph.compile(graph)

    assert {:error,
            %Error{
              type: :invalid_graph,
              message: "graph contains dead-end nodes",
              details: %{nodes: ["dead"]}
            }} = Graph.compile(graph, validate_static: true)
  end

  test "runtime injection, module nodes, and input/output projection use Elixir runtime structs" do
    # Translates Python injection/config tests to BeamWeaver's single Runtime struct.
    checkpointer = CheckpointETS.new()

    config = %{
      "configurable" => %{
        "thread_id" => "runtime-injection",
        "assistant_id" => "assistant-runtime",
        "graph_id" => "runtime-graph",
        "langgraph_auth_user" => %{
          "identity" => "user-runtime",
          "display_name" => "Runtime User",
          "permissions" => ["read"]
        }
      }
    }

    graph =
      Graph.new()
      |> Graph.add_node(
        :inspect_runtime,
        %RuntimeStructNode{caller: self()},
        input: fn state, runtime ->
          %{value: state.value, runtime_node: runtime.node}
        end,
        output: fn output, state, runtime ->
          %{projected: output.seen, original: state.value, runtime_node: runtime.node}
        end
      )
      |> Graph.add_node(:module_node, ModuleNode)
      |> Graph.add_edge(:inspect_runtime, :module_node)
      |> Graph.add_edge(Graph.start(), :inspect_runtime)
      |> Graph.add_edge(:module_node, Graph.end_node())
      |> Graph.compile!(checkpointer: checkpointer, name: "RuntimeGraph")

    assert {:ok,
            %{
              projected: 1,
              original: 1,
              runtime_node: "inspect_runtime",
              module_node: "1:module_node"
            }} = Compiled.invoke(graph, %{value: 1}, config: config, context: %{user_id: "u-1"})

    assert_receive {:runtime_seen, runtime}
    assert runtime.context == %{user_id: "u-1"}
    assert runtime.config["configurable"]["thread_id"] == "runtime-injection"
    assert runtime.graph_name == "RuntimeGraph"
    assert runtime.node == "inspect_runtime"
    assert runtime.step == 0
    assert runtime.task_id?
    assert runtime.namespace == []
    assert runtime.previous_state.value == 1
    assert runtime.checkpoint["configurable"]["thread_id"] == "runtime-injection"
    assert runtime.execution.node == "inspect_runtime"
    assert %ServerInfo{} = runtime.server_info
    assert runtime.server_info.assistant_id == "assistant-runtime"
    assert runtime.server_info.graph_id == "runtime-graph"
    assert runtime.server_info.user.identity == "user-runtime"
    assert runtime.server_info.user["display_name"] == "Runtime User"
  end

  test "runtime merge override and server info hydration stay immutable" do
    server_info = ServerInfo.new(assistant_id: "assistant-1", graph_id: "graph-1")
    base = %Runtime{context: %{api_key: "abc"}, server_info: server_info, run_id: "run-1"}

    assert %Runtime{context: %{api_key: "def"}, server_info: ^server_info, run_id: "run-1"} =
             Runtime.merge(base, %Runtime{context: %{api_key: "def"}})

    assert %Runtime{context: nil, server_info: ^server_info} =
             Runtime.override(base, context: nil)

    refute Map.has_key?(
             Map.from_struct(Runtime.merge(base, %{unknown_field: true})),
             :unknown_field
           )

    assert %ServerInfo{assistant_id: "assistant-2", graph_id: "graph-2", user: user} =
             ServerInfo.from_configurable(%{
               "assistant_id" => "assistant-2",
               "graph_id" => "graph-2",
               "langgraph_auth_user" => %{
                 "identity" => "user-2",
                 "display_name" => "User Two",
                 "is_authenticated" => true,
                 "permissions" => ["read", "write"]
               }
             })

    assert user.identity == "user-2"
    assert user.display_name == "User Two"
    assert user.permissions == ["read", "write"]
    assert user["display_name"] == "User Two"
    assert ServerInfo.from_configurable(%{}) == nil
  end

  test "runnable, tool, model, and compiled subgraph nodes convert through explicit node specs" do
    # Translates LangGraph node coercion tests to BeamWeaver.IntoNode protocol coverage.
    tool =
      Tool.from_function!(
        name: "double",
        description: "Double a value.",
        input_schema: %{
          "type" => "object",
          "properties" => %{"value" => %{"type" => "integer"}},
          "required" => ["value"]
        },
        handler: fn input, _opts -> {:ok, input["value"] * 2} end
      )

    subgraph =
      Graph.new()
      |> Graph.add_node(:inside, fn state -> %{subgraph_value: state.value + 1} end)
      |> Graph.add_edge(Graph.start(), :inside)
      |> Graph.add_edge(:inside, Graph.end_node())
      |> Graph.compile!()

    model = %FakeChatModel{response: Message.assistant("model")}

    graph =
      Graph.new()
      |> Graph.add_node(
        :runnable,
        Runnable.lambda(fn state -> {:ok, %{value: state.value + 1}} end)
      )
      |> Graph.add_node(:tool, tool, input: fn state -> %{input: %{"value" => state.value}} end)
      |> Graph.add_node(:model, model)
      |> Graph.add_node(:subgraph, subgraph)
      |> Graph.add_edge(:runnable, :tool)
      |> Graph.add_edge(:tool, :model)
      |> Graph.add_edge(:model, :subgraph)
      |> Graph.add_edge(Graph.start(), :runnable)
      |> Graph.add_edge(:subgraph, Graph.end_node())
      |> Graph.compile!()

    assert {:ok, result} =
             Compiled.invoke(graph, %{value: 1, messages: [Message.user("hi")]})

    assert result.value == 2
    assert result.tool_result == 4
    assert Enum.any?(result.messages, &(&1.role == :assistant and &1.content == "model"))
    assert result.subgraph_value == 3

    nodes = Compiled.get_graph(graph).nodes
    assert nodes["runnable"].kind == :runnable
    assert nodes["tool"].kind == :tool
    assert nodes["model"].kind == :model
    assert nodes["subgraph"].kind == :subgraph
  end

  test "node policy structs are normalized and retry failures according to the shared policy" do
    # Translates LangGraph retry-policy node coverage to BeamWeaver shared policy structs.
    {:ok, attempts} = Agent.start_link(fn -> 0 end)
    {:ok, seen_execution} = Agent.start_link(fn -> [] end)

    retry_policy = RetryPolicy.new!(max_attempts: 3, retry_on: :transient, initial_delay: 0)
    execution_policy = ExecutionPolicy.new!(timeout: 1_000, metadata: %{kind: :node})
    cache_policy = CachePolicy.new!(namespace: :runtime_surface, ttl: 1_000)

    graph =
      Graph.new()
      |> Graph.add_node(
        :flaky,
        fn _state, runtime ->
          count = Agent.get_and_update(attempts, &{&1 + 1, &1 + 1})

          Agent.update(seen_execution, fn seen ->
            seen ++
              [
                %{
                  attempt: runtime.execution.node_attempt,
                  first_attempt_time: runtime.execution.node_first_attempt_time,
                  thread_id: runtime.execution.thread_id,
                  task_id: runtime.execution.task_id
                }
              ]
          end)

          if count < 3,
            do: {:error, Error.new(:transient, "try again")},
            else: %{ok: true, attempts: count}
        end,
        retry: retry_policy,
        timeout: execution_policy,
        cache: cache_policy
      )
      |> Graph.add_edge(Graph.start(), :flaky)
      |> Graph.add_edge(:flaky, Graph.end_node())
      |> Graph.compile!(cache: Cache.ETS.new())

    assert {:ok, %{ok: true, attempts: 3}} =
             Compiled.invoke(graph, %{}, config: %{"configurable" => %{"thread_id" => "retry-thread"}})

    node = Compiled.get_graph(graph).nodes["flaky"]
    assert node.retry == retry_policy
    assert node.timeout == execution_policy
    assert node.cache == cache_policy

    seen = Agent.get(seen_execution, & &1)
    assert Enum.map(seen, & &1.attempt) == [1, 2, 3]
    assert Enum.uniq(Enum.map(seen, & &1.first_attempt_time)) |> length() == 1
    assert Enum.all?(seen, &(&1.thread_id == "retry-thread"))
    assert Enum.all?(seen, &is_binary(&1.task_id))
  end

  test "node retry exhaustion returns the final tagged error" do
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    graph =
      Graph.new()
      |> Graph.add_node(
        :flaky,
        fn _state ->
          count = Agent.get_and_update(attempts, &{&1 + 1, &1 + 1})
          {:error, Error.new(:transient, "attempt #{count}")}
        end,
        retry: RetryPolicy.new!(max_attempts: 2, retry_on: :transient, initial_delay: 0)
      )
      |> Graph.add_edge(Graph.start(), :flaky)
      |> Graph.add_edge(:flaky, Graph.end_node())
      |> Graph.compile!()

    assert {:error, %Error{type: :transient, message: "attempt 2"}} =
             Compiled.invoke(graph, %{})

    assert Agent.get(attempts, & &1) == 2
  end

  test "node defaults apply retry and timeout while per-node policy wins" do
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    default_retry = RetryPolicy.new!(max_attempts: 2, retry_on: :transient, initial_delay: 0)
    custom_retry = RetryPolicy.new!(max_attempts: 4, retry_on: :custom, initial_delay: 0)

    graph =
      Graph.new()
      |> Graph.set_node_defaults(retry: default_retry)
      |> Graph.set_node_defaults(timeout: 250)
      |> Graph.add_node(:flaky, fn _state ->
        count = Agent.get_and_update(attempts, &{&1 + 1, &1 + 1})

        if count < 2,
          do: {:error, Error.new(:transient, "try again")},
          else: %{attempts: count}
      end)
      |> Graph.add_node(:custom, fn state -> state end, retry: custom_retry, timeout: 50)
      |> Graph.add_edge(Graph.start(), :flaky)
      |> Graph.add_edge(:flaky, Graph.end_node())
      |> Graph.compile!()

    assert {:ok, %{attempts: 2}} = Compiled.invoke(graph, %{})

    nodes = Compiled.get_graph(graph).nodes
    assert nodes["flaky"].retry == default_retry
    assert nodes["flaky"].timeout.timeout == 250
    assert nodes["custom"].retry == custom_retry
    assert nodes["custom"].timeout.timeout == 50
  end

  test "node error handler recovers after retry exhaustion with runtime context" do
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    graph =
      Graph.new()
      |> Graph.add_node(
        :flaky,
        fn _state ->
          count = Agent.get_and_update(attempts, &{&1 + 1, &1 + 1})
          {:error, Error.new(:transient, "attempt #{count} failed")}
        end,
        retry: RetryPolicy.new!(max_attempts: 2, retry_on: :transient, initial_delay: 0),
        error_handler: fn error, state, runtime ->
          %{
            recovered: true,
            error_type: error.type,
            input: state.input,
            node: runtime.node,
            final_attempt: runtime.execution.node_attempt,
            thread_id: runtime.execution.thread_id
          }
        end
      )
      |> Graph.add_edge(Graph.start(), :flaky)
      |> Graph.add_edge(:flaky, Graph.end_node())
      |> Graph.compile!()

    assert {:ok,
            %{
              recovered: true,
              error_type: :transient,
              input: "payload",
              node: "flaky",
              final_attempt: 2,
              thread_id: "error-handler-thread"
            }} =
             Compiled.invoke(graph, %{input: "payload"},
               config: %{"configurable" => %{"thread_id" => "error-handler-thread"}}
             )
  end

  test "node error handler can route with a command" do
    graph =
      Graph.new()
      |> Graph.add_node(
        :flaky,
        fn _state -> {:error, Error.new(:transient, "route me")} end,
        retry: RetryPolicy.new!(max_attempts: 1, retry_on: :transient, initial_delay: 0),
        error_handler: fn error ->
          %Command{update: %{handled_error: error.type}, goto: :recovered}
        end
      )
      |> Graph.add_node(:recovered, fn state ->
        %{routed: true, handled_error: state.handled_error}
      end)
      |> Graph.add_edge(Graph.start(), :flaky)
      |> Graph.add_edge(:recovered, Graph.end_node())
      |> Graph.compile!()

    assert {:ok, %{routed: true, handled_error: :transient}} = Compiled.invoke(graph, %{})
  end

  test "checkpointed error handler crash resumes handler without rerunning failed node" do
    checkpointer = CheckpointETS.new()
    {:ok, calls} = Agent.start_link(fn -> %{node: 0, handler: 0, handler_fails?: true} end)

    graph =
      Graph.new()
      |> Graph.add_node(
        :fail,
        fn _state ->
          Agent.update(calls, &Map.update!(&1, :node, fn count -> count + 1 end))
          raise "boom"
        end,
        error_handler: fn error, _state, runtime ->
          Agent.update(calls, &Map.update!(&1, :handler, fn count -> count + 1 end))

          if Agent.get(calls, & &1.handler_fails?) do
            raise "handler crash"
          end

          %{recovered: true, error_type: error.type, node: runtime.node}
        end
      )
      |> Graph.add_edge(Graph.start(), :fail)
      |> Graph.add_edge(:fail, Graph.end_node())
      |> Graph.compile!(checkpointer: checkpointer)

    config = %{"configurable" => %{"thread_id" => "error-handler-resume"}}

    assert {:error, %Error{type: :node_error_handler_failed, message: "handler crash"}} =
             Compiled.invoke(graph, %{}, config: config)

    assert Agent.get(calls, & &1) == %{node: 1, handler: 1, handler_fails?: true}

    Agent.update(calls, &%{&1 | handler_fails?: false})

    assert {:ok, %{recovered: true, error_type: :node_exception, node: "fail"}} =
             Compiled.resume(graph, nil, config: config)

    assert Agent.get(calls, & &1) == %{node: 1, handler: 2, handler_fails?: false}
  end

  test "checkpointed parallel error handlers resume without rerunning failed nodes" do
    checkpointer = CheckpointETS.new()

    {:ok, calls} =
      Agent.start_link(fn ->
        %{a: 0, b: 0, handler_a: 0, handler_b: 0, handlers_fail?: true}
      end)

    fail = fn key, message ->
      fn _state ->
        Agent.update(calls, &Map.update!(&1, key, fn count -> count + 1 end))
        raise message
      end
    end

    handler = fn key, label ->
      fn error, _state, _runtime ->
        Agent.update(calls, &Map.update!(&1, key, fn count -> count + 1 end))

        if Agent.get(calls, & &1.handlers_fail?) do
          raise "#{label} handler crash"
        end

        %{results: ["recovered_#{label}:#{error.type}"]}
      end
    end

    graph =
      Graph.new()
      |> Graph.add_reducer(:results, fn existing, update -> existing ++ List.wrap(update) end)
      |> Graph.add_node(:a, fail.(:a, "a failed"), error_handler: handler.(:handler_a, "a"))
      |> Graph.add_node(:b, fail.(:b, "b failed"), error_handler: handler.(:handler_b, "b"))
      |> Graph.add_edge(Graph.start(), :a)
      |> Graph.add_edge(Graph.start(), :b)
      |> Graph.add_edge(:a, Graph.end_node())
      |> Graph.add_edge(:b, Graph.end_node())
      |> Graph.compile!(checkpointer: checkpointer)

    config = %{"configurable" => %{"thread_id" => "parallel-error-handler-resume"}}

    assert {:error, %Error{type: :node_error_handler_failed}} =
             Compiled.invoke(graph, %{results: []}, config: config)

    assert Agent.get(calls, &Map.take(&1, [:a, :b, :handler_a, :handler_b])) == %{
             a: 1,
             b: 1,
             handler_a: 1,
             handler_b: 1
           }

    Agent.update(calls, &%{&1 | handlers_fail?: false})

    assert {:ok, %{results: results}} = Compiled.resume(graph, nil, config: config)
    assert Enum.sort(results) == ["recovered_a:node_exception", "recovered_b:node_exception"]

    assert Agent.get(calls, &Map.take(&1, [:a, :b, :handler_a, :handler_b])) == %{
             a: 1,
             b: 1,
             handler_a: 2,
             handler_b: 2
           }
  end

  test "parent node error handler can recover a compiled subgraph failure" do
    child =
      Graph.new()
      |> Graph.add_node(:inside, fn _state -> raise "subgraph boom" end)
      |> Graph.add_edge(Graph.start(), :inside)
      |> Graph.add_edge(:inside, Graph.end_node())
      |> Graph.compile!()

    graph =
      Graph.new()
      |> Graph.add_node(
        :child,
        child,
        error_handler: fn error, _state, runtime ->
          %{recovered_by: runtime.node, subgraph_error: error.type}
        end
      )
      |> Graph.add_edge(Graph.start(), :child)
      |> Graph.add_edge(:child, Graph.end_node())
      |> Graph.compile!()

    assert {:ok, %{recovered_by: "child", subgraph_error: :node_exception}} =
             Compiled.invoke(graph, %{})
  end

  test "node default error handler can be overridden per node and handler failures fail the run" do
    default_handler = fn error, _state, runtime ->
      %{handled_by: :default, node: runtime.node, error_type: error.type}
    end

    graph =
      Graph.new()
      |> Graph.set_node_defaults(error_handler: default_handler)
      |> Graph.add_node(:defaulted, fn _state ->
        {:error, Error.new(:default_error, "default")}
      end)
      |> Graph.add_node(
        :custom,
        fn _state -> {:error, Error.new(:custom_error, "custom")} end,
        error_handler: fn _error -> %{handled_by: :custom} end
      )
      |> Graph.add_node(
        :bad_handler,
        fn _state -> {:error, Error.new(:bad_error, "bad")} end,
        error_handler: fn _error -> raise "handler exploded" end
      )
      |> Graph.add_edge(Graph.start(), :defaulted)
      |> Graph.add_edge(:defaulted, Graph.end_node())
      |> Graph.compile!()

    assert {:ok, %{handled_by: :default, node: "defaulted", error_type: :default_error}} =
             Compiled.invoke(graph, %{})

    custom_graph =
      Graph.new()
      |> Graph.set_node_defaults(error_handler: default_handler)
      |> Graph.add_node(
        :custom,
        fn _state -> {:error, Error.new(:custom_error, "custom")} end,
        error_handler: fn _error -> %{handled_by: :custom} end
      )
      |> Graph.add_edge(Graph.start(), :custom)
      |> Graph.add_edge(:custom, Graph.end_node())
      |> Graph.compile!()

    assert {:ok, %{handled_by: :custom}} = Compiled.invoke(custom_graph, %{})

    failing_graph =
      Graph.new()
      |> Graph.add_node(
        :bad_handler,
        fn _state -> {:error, Error.new(:bad_error, "bad")} end,
        error_handler: fn _error -> raise "handler exploded" end
      )
      |> Graph.add_edge(Graph.start(), :bad_handler)
      |> Graph.add_edge(:bad_handler, Graph.end_node())
      |> Graph.compile!()

    assert {:error, %Error{type: :node_error_handler_failed, message: "handler exploded"}} =
             Compiled.invoke(failing_graph, %{})
  end

  test "node defaults combine retry and error handler policies" do
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    default_retry = RetryPolicy.new!(max_attempts: 2, retry_on: :transient, initial_delay: 0)

    graph =
      Graph.new()
      |> Graph.set_node_defaults(retry: default_retry)
      |> Graph.set_node_defaults(
        error_handler: fn error, _state, runtime ->
          %{handled: true, error_type: error.type, final_attempt: runtime.execution.node_attempt}
        end
      )
      |> Graph.add_node(:flaky, fn _state ->
        count = Agent.get_and_update(attempts, &{&1 + 1, &1 + 1})
        {:error, Error.new(:transient, "attempt #{count}")}
      end)
      |> Graph.add_edge(Graph.start(), :flaky)
      |> Graph.add_edge(:flaky, Graph.end_node())
      |> Graph.compile!()

    assert {:ok, %{handled: true, error_type: :transient, final_attempt: 2}} =
             Compiled.invoke(graph, %{})

    assert Agent.get(attempts, & &1) == 2
  end

  test "invalid input and output projections return tagged node errors" do
    graph =
      Graph.new()
      |> Graph.add_node(:bad_input, fn state -> state end, input: :not_a_projection)
      |> Graph.add_edge(Graph.start(), :bad_input)
      |> Graph.add_edge(:bad_input, Graph.end_node())
      |> Graph.compile!()

    assert {:error, %Error{type: :invalid_node_input_projection}} =
             Compiled.invoke(graph, %{})

    graph =
      Graph.new()
      |> Graph.add_node(:bad_output, fn state -> state end, output: {:bad, :projection})
      |> Graph.add_edge(Graph.start(), :bad_output)
      |> Graph.add_edge(:bad_output, Graph.end_node())
      |> Graph.compile!()

    assert {:error, %Error{type: :invalid_node_output_projection}} =
             Compiled.invoke(graph, %{})
  end

  test "update_state returns a tagged ambiguity error when continuation cannot be inferred" do
    # Translates LangGraph update-state as_node ambiguity behavior to tagged Elixir errors.
    checkpointer = CheckpointETS.new()

    graph =
      Graph.new()
      |> Graph.add_node(:fanout, fn _state ->
        [
          %BeamWeaver.Graph.Send{node: :left},
          %BeamWeaver.Graph.Send{node: :right}
        ]
      end)
      |> Graph.add_node(:left, fn _state -> %{left: true} end)
      |> Graph.add_node(:right, fn _state -> %{right: true} end)
      |> Graph.add_node(:after_left, fn state -> %{after_left: state.left} end)
      |> Graph.add_node(:after_right, fn state -> %{after_right: state.right} end)
      |> Graph.add_edge(:left, :after_left)
      |> Graph.add_edge(:right, :after_right)
      |> Graph.add_edge(Graph.start(), :fanout)
      |> Graph.add_edge(:after_left, Graph.end_node())
      |> Graph.add_edge(:after_right, Graph.end_node())
      |> Graph.compile!(checkpointer: checkpointer, interrupt_after: [:left, :right])

    config = %{"configurable" => %{"thread_id" => "ambiguous-update"}}

    assert {:interrupted, _interrupt} = Compiled.invoke(graph, %{}, config: config)

    assert {:error,
            %Error{
              type: :ambiguous_state_update,
              details: %{nodes: nodes}
            }} = Compiled.update_state(graph, config, %{reviewed: true})

    assert Enum.sort(nodes) == ["left", "right"]
  end

  test "bulk_update_state rejects empty batches instead of silently creating checkpoints" do
    # Translates LangGraph test_pregel.py::test_bulk_state_updates empty-input failures.
    checkpointer = CheckpointETS.new()

    graph =
      Graph.new()
      |> Graph.add_node(:noop, fn state -> state end)
      |> Graph.add_edge(Graph.start(), :noop)
      |> Graph.add_edge(:noop, Graph.end_node())
      |> Graph.compile!(checkpointer: checkpointer)

    config = %{"configurable" => %{"thread_id" => "bulk-empty"}}

    assert {:error,
            %Error{
              type: :invalid_update,
              message: "bulk update requires at least one superstep"
            }} = Compiled.bulk_update_state(graph, config, [])

    assert {:error, %Error{type: :invalid_update, message: "bulk update supersteps cannot be empty"}} =
             Compiled.bulk_update_state(graph, config, [[]])
  end
end
