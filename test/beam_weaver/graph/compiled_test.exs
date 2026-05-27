defmodule BeamWeaver.Graph.CompiledTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Checkpoint.ETS, as: CheckpointETS
  alias BeamWeaver.Core.Async
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Graph
  alias BeamWeaver.Graph.Command
  alias BeamWeaver.Graph.Compiled
  alias BeamWeaver.Graph.Messages
  alias BeamWeaver.Graph.Overwrite
  alias BeamWeaver.Graph.Send
  alias BeamWeaver.Stream
  alias BeamWeaver.Stream.Envelope
  alias BeamWeaver.Stream.Events
  alias BeamWeaver.TimeoutPolicy

  @uuidv7_regex ~r/^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/

  defmodule StructState do
    defstruct foo: ""
  end

  defmodule ContextSchema do
    use BeamWeaver.Graph.Schema

    field(:x, :integer, required: true, metadata: %{"title" => "X"})
    field(:y, :string, metadata: %{"title" => "Y", "default" => "foo"})
  end

  test "runs a conditional graph and merges parallel node updates through reducers" do
    graph =
      Graph.new()
      |> Graph.add_reducer(:items, fn existing, update -> existing ++ List.wrap(update) end)
      |> Graph.add_node(:route, fn state ->
        if state[:fanout], do: %Command{goto: :fanout}, else: %Command{goto: :direct}
      end)
      |> Graph.add_node(:direct, fn _state -> %{items: [:direct]} end)
      |> Graph.add_node(:fanout, fn _state ->
        [
          %Send{node: :worker, update: %{item: :a}},
          %Send{node: :worker, update: %{item: :b}}
        ]
      end)
      |> Graph.add_node(:worker, fn state -> %{items: [state.item]} end)
      |> Graph.add_edge(Graph.start(), :route)
      |> Graph.add_edge(:direct, Graph.end_node())
      |> Graph.add_edge(:worker, Graph.end_node())
      |> Graph.compile!()

    assert {:ok, %{items: [:direct]}} = Compiled.invoke(graph, %{fanout: false, items: []})

    assert {:ok, %{items: items}} = Compiled.invoke(graph, %{fanout: true, items: []})
    assert Enum.sort(items) == [:a, :b]
  end

  test "mixed command and map node returns preserve ordered reducer writes" do
    graph =
      Graph.new()
      |> Graph.add_reducer(:foo, fn existing, update -> existing <> update end)
      |> Graph.add_node(:my_node, fn _state ->
        [
          %Command{update: %{foo: "a"}},
          %{foo: "b"}
        ]
      end)
      |> Graph.add_edge(Graph.start(), :my_node)
      |> Graph.add_edge(:my_node, Graph.end_node())
      |> Graph.compile!()

    assert {:ok, %{foo: "ab"}} = Compiled.invoke(graph, %{foo: ""})
  end

  test "command update accepts native schema structs" do
    graph =
      Graph.new()
      |> Graph.add_node(:node_a, fn _state ->
        %Command{update: %StructState{foo: "foo"}, goto: :node_b}
      end)
      |> Graph.add_node(:node_b, fn state -> %{foo: state.foo <> "bar"} end)
      |> Graph.add_edge(Graph.start(), :node_a)
      |> Graph.add_edge(:node_b, Graph.end_node())
      |> Graph.compile!()

    assert {:ok, %{foo: "foobar"}} = Compiled.invoke(graph, %StructState{})
  end

  test "compiled graph exposes context JSON schema from native schema modules" do
    graph =
      Graph.new(context_schema: ContextSchema)
      |> Graph.add_node(:node, fn state -> state end)
      |> Graph.add_edge(Graph.start(), :node)
      |> Graph.add_edge(:node, Graph.end_node())
      |> Graph.compile!()

    assert Compiled.get_context_json_schema(graph) == %{
             "type" => "object",
             "properties" => %{
               "x" => %{"type" => "integer", "title" => "X"},
               "y" => %{"type" => "string", "title" => "Y", "default" => "foo"}
             },
             "required" => ["x"]
           }
  end

  test "graph input and output schemas project public state while reducers prepare node input" do
    graph =
      Graph.new(
        state_schema: Messages.state_schema(),
        input_schema: %{hello: :string, bye: :string, messages: :list},
        output_schema: %{messages: :list}
      )
      |> Graph.add_node(
        :a,
        fn state ->
          assert %{hello: "there", messages: [%Message{role: :user, content: "hello"}]} = state
          nil
        end,
        input: [:hello, :messages]
      )
      |> Graph.add_node(
        :b,
        fn state ->
          assert state == %{bye: "world"}
          %{now: 123, hello: "again"}
        end,
        input: [:bye]
      )
      |> Graph.add_node(
        :c,
        fn state ->
          assert state == %{hello: "again", now: 123}
          nil
        end,
        input: [:hello, :now]
      )
      |> Graph.add_edge(Graph.start(), :a)
      |> Graph.add_edge(:a, :b)
      |> Graph.add_edge(:b, :c)
      |> Graph.add_edge(:c, Graph.end_node())
      |> Graph.compile!()

    assert {:ok, %{messages: [%Message{role: :user, content: "hello"}]}} =
             Compiled.invoke(graph, %{
               hello: "there",
               bye: "world",
               messages: "hello",
               now: 345
             })

    assert Compiled.get_input_json_schema(graph) == %{
             hello: :string,
             bye: :string,
             messages: :list
           }

    assert Compiled.get_output_json_schema(graph) == %{messages: :list}
  end

  test "single node input/output schemas support fixed and computed writes" do
    graph =
      Graph.new(
        input_schema: %{input: :integer},
        output_schema: %{output: :integer, fixed: :integer, output_plus_one: :integer}
      )
      |> Graph.add_node(
        :one,
        fn state ->
          output = state.input + 1
          %{output: output, fixed: 5, output_plus_one: output + 1, internal: :hidden}
        end,
        input: [:input]
      )
      |> Graph.add_edge(Graph.start(), :one)
      |> Graph.add_edge(:one, Graph.end_node())
      |> Graph.compile!()

    assert Compiled.get_context_json_schema(graph) == %{}

    assert {:ok, %{output: 3, fixed: 5, output_plus_one: 4}} =
             Compiled.invoke(graph, %{input: 2, ignored: true})

    assert Compiled.get_graph(graph).output_channels == [
             "fixed",
             "output",
             "output_plus_one"
           ]
  end

  test "rejects parallel writes to a last-value state key" do
    graph =
      Graph.new()
      |> Graph.add_node(:fanout, fn _state ->
        [
          %Send{node: :worker, update: %{item: :a}},
          %Send{node: :worker, update: %{item: :b}}
        ]
      end)
      |> Graph.add_node(:worker, fn state -> %{answer: state.item} end)
      |> Graph.add_edge(Graph.start(), :fanout)
      |> Graph.add_edge(:worker, Graph.end_node())
      |> Graph.compile!()

    assert {:error,
            %Error{
              type: :invalid_update,
              message: "last-value channel can receive only one value per step",
              details: %{channel: :answer}
            }} = Compiled.invoke(graph, %{})
  end

  test "overwrites reducer state once within a parallel step" do
    graph =
      Graph.new()
      |> Graph.add_reducer(:items, fn existing, update -> existing ++ List.wrap(update) end)
      |> Graph.add_node(:fanout, fn _state ->
        [
          %Send{node: :reset},
          %Send{node: :append}
        ]
      end)
      |> Graph.add_node(:reset, fn _state -> %{items: %Overwrite{value: [:reset]}} end)
      |> Graph.add_node(:append, fn _state -> %{items: [:new]} end)
      |> Graph.add_edge(Graph.start(), :fanout)
      |> Graph.add_edge(:reset, Graph.end_node())
      |> Graph.add_edge(:append, Graph.end_node())
      |> Graph.compile!()

    # Upstream LangGraph BinaryOperatorAggregate ignores same-step values after
    # an Overwrite.
    assert {:ok, %{items: [:reset]}} = Compiled.invoke(graph, %{items: [:old]})
  end

  test "times out slow nodes and cancels pending siblings" do
    parent = self()

    graph =
      Graph.new()
      |> Graph.add_node(:fanout, fn _state ->
        [
          %Send{node: :slow},
          %Send{node: :sibling}
        ]
      end)
      |> Graph.add_node(
        :slow,
        fn _state ->
          Process.sleep(100)
          %{slow: true}
        end,
        timeout: 10
      )
      |> Graph.add_node(
        :sibling,
        fn _state ->
          Process.sleep(80)
          send(parent, :sibling_finished)
          %{sibling: true}
        end,
        timeout: 1_000
      )
      |> Graph.add_edge(Graph.start(), :fanout)
      |> Graph.add_edge(:slow, Graph.end_node())
      |> Graph.add_edge(:sibling, Graph.end_node())
      |> Graph.compile!()

    assert {:error,
            %Error{
              type: :node_timeout,
              message: "node timed out",
              details: %{node: "slow", step: 1, timeout: 10}
            }} = Compiled.invoke(graph, %{})

    refute_receive :sibling_finished, 150
  end

  test "send timeout overrides the target node timeout" do
    graph =
      Graph.new()
      |> Graph.add_node(:fanout, fn _state ->
        %Send{node: :slow, update: %{source: :send}, timeout: 10}
      end)
      |> Graph.add_node(
        :slow,
        fn _state ->
          Process.sleep(80)
          %{slow: true}
        end,
        timeout: 1_000
      )
      |> Graph.add_edge(Graph.start(), :fanout)
      |> Graph.add_edge(:slow, Graph.end_node())
      |> Graph.compile!()

    assert {:error,
            %Error{
              type: :node_timeout,
              details: %{node: "slow", step: 1, timeout: 10}
            }} = Compiled.invoke(graph, %{})
  end

  test "float timeout durations normalize to milliseconds and report active budgets" do
    graph =
      Graph.new()
      |> Graph.add_node(
        :slow,
        fn _state ->
          Process.sleep(80)
          %{slow: true}
        end,
        timeout: 0.01
      )
      |> Graph.add_edge(Graph.start(), :slow)
      |> Graph.add_edge(:slow, Graph.end_node())
      |> Graph.compile!(step_timeout: 0.5, run_timeout: 1.0)

    assert {:error,
            %Error{
              type: :node_timeout,
              details: %{
                node: "slow",
                timeout: 10,
                node_timeout: 10,
                step_timeout: 500,
                run_timeout: 1_000
              }
            }} = Compiled.invoke(graph, %{})
  end

  test "timeout policy structs normalize at graph and dynamic send boundaries" do
    graph =
      Graph.new()
      |> Graph.add_node(
        :slow,
        fn _state ->
          Process.sleep(80)
          %{slow: true}
        end,
        timeout: TimeoutPolicy.new!(idle_timeout: 0.01, run_timeout: 0.5)
      )
      |> Graph.add_edge(Graph.start(), :slow)
      |> Graph.add_edge(:slow, Graph.end_node())
      |> Graph.compile!()

    assert {:error,
            %Error{
              type: :node_timeout,
              details: %{node: "slow", timeout: 10, node_timeout: 10}
            }} = Compiled.invoke(graph, %{})

    send_graph =
      Graph.new()
      |> Graph.add_node(
        :fanout,
        fn _state ->
          %Send{
            node: :slow,
            update: %{source: :send},
            timeout: TimeoutPolicy.new!(idle_timeout: 0.01)
          }
        end
      )
      |> Graph.add_node(
        :slow,
        fn _state ->
          Process.sleep(80)
          %{slow: true}
        end,
        timeout: 1_000
      )
      |> Graph.add_edge(Graph.start(), :fanout)
      |> Graph.add_edge(:slow, Graph.end_node())
      |> Graph.compile!()

    assert {:error,
            %Error{
              type: :node_timeout,
              details: %{node: "slow", timeout: 10, node_timeout: 10}
            }} = Compiled.invoke(send_graph, %{})
  end

  test "node timeout participates in retry policy before surfacing error" do
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    graph =
      Graph.new()
      |> Graph.add_node(
        :flaky_timeout,
        fn _state ->
          attempt = Agent.get_and_update(attempts, &{&1 + 1, &1 + 1})

          if attempt == 1 do
            Process.sleep(80)
          end

          %{attempt: attempt}
        end,
        timeout: 10,
        retry:
          BeamWeaver.RetryPolicy.new!(
            max_attempts: 2,
            initial_delay: 0,
            retry_on: :node_timeout
          )
      )
      |> Graph.add_edge(Graph.start(), :flaky_timeout)
      |> Graph.add_edge(:flaky_timeout, Graph.end_node())
      |> Graph.compile!()

    assert {:ok, %{attempt: 2}} = Compiled.invoke(graph, %{})
    assert Agent.get(attempts, & &1) == 2
  end

  test "step timeout caps the whole superstep" do
    parent = self()

    graph =
      Graph.new()
      |> Graph.add_node(:fanout, fn _state ->
        [
          %Send{node: :slow_a},
          %Send{node: :slow_b}
        ]
      end)
      |> Graph.add_node(
        :slow_a,
        fn _state ->
          Process.sleep(100)
          send(parent, :slow_a_finished)
          %{a: true}
        end,
        timeout: 1_000
      )
      |> Graph.add_node(
        :slow_b,
        fn _state ->
          Process.sleep(100)
          send(parent, :slow_b_finished)
          %{b: true}
        end,
        timeout: 1_000
      )
      |> Graph.add_edge(Graph.start(), :fanout)
      |> Graph.add_edge(:slow_a, Graph.end_node())
      |> Graph.add_edge(:slow_b, Graph.end_node())
      |> Graph.compile!(step_timeout: 10)

    assert {:error,
            %Error{
              type: :step_timeout,
              message: "graph step timed out",
              details: %{timeout: 10}
            }} = Compiled.invoke(graph, %{})

    refute_receive :slow_a_finished, 150
    refute_receive :slow_b_finished, 150
  end

  test "run timeout caps the whole invocation and overrides proceed failure policy" do
    parent = self()

    graph =
      Graph.new()
      |> Graph.add_node(:fanout, fn _state ->
        [
          %Send{node: :slow_a},
          %Send{node: :slow_b}
        ]
      end)
      |> Graph.add_node(
        :slow_a,
        fn _state ->
          Process.sleep(100)
          send(parent, :slow_a_finished)
          %{a: true}
        end,
        timeout: 1_000
      )
      |> Graph.add_node(
        :slow_b,
        fn _state ->
          Process.sleep(100)
          send(parent, :slow_b_finished)
          %{b: true}
        end,
        timeout: 1_000
      )
      |> Graph.add_edge(Graph.start(), :fanout)
      |> Graph.add_edge(:slow_a, Graph.end_node())
      |> Graph.add_edge(:slow_b, Graph.end_node())
      |> Graph.compile!(failure_policy: :proceed, step_timeout: 1_000, run_timeout: 10)

    assert {:error,
            %Error{
              type: :run_timeout,
              message: "graph run timed out",
              details: %{timeout: 10}
            }} = Compiled.invoke(graph, %{})

    refute_receive :slow_a_finished, 150
    refute_receive :slow_b_finished, 150
  end

  test "recursion limit caps executed supersteps" do
    parent = self()

    graph =
      Graph.new()
      |> Graph.add_node(:loop, fn state ->
        count = Map.get(state, :count, 0)
        send(parent, {:loop_step, count})
        %Command{update: %{count: count + 1}, goto: :loop}
      end)
      |> Graph.add_edge(Graph.start(), :loop)
      |> Graph.compile!()

    assert {:error,
            %Error{
              type: :recursion_limit,
              message: "graph recursion limit reached",
              details: %{limit: 2, step: 2}
            }} = Compiled.invoke(graph, %{}, recursion_limit: 2)

    assert_receive {:loop_step, 0}
    assert_receive {:loop_step, 1}
    refute_receive {:loop_step, 2}, 50
  end

  test "persists state by thread, exposes history, and supports manual state updates" do
    checkpointer = CheckpointETS.new()

    graph =
      Graph.new()
      |> Graph.add_node(:increment, fn state -> %{count: Map.get(state, :count, 0) + 1} end)
      |> Graph.add_edge(Graph.start(), :increment)
      |> Graph.add_edge(:increment, Graph.end_node())
      |> Graph.compile!(checkpointer: checkpointer)

    config = %{"configurable" => %{"thread_id" => "counter"}}

    assert {:ok, %{count: 1}} = Compiled.invoke(graph, %{}, config: config)
    assert {:ok, %{count: 2}} = Compiled.invoke(graph, %{}, config: config)

    assert {:ok, snapshot} = Compiled.get_state(graph, config)
    assert snapshot.values.count == 2
    assert is_binary(snapshot.created_at)
    assert snapshot.next == []
    assert snapshot.interrupts == []
    assert snapshot.parent_config["configurable"]["checkpoint_id"]
    assert Enum.map(snapshot.tasks, & &1.kind) == [:start, :finish]
    assert Enum.map(snapshot.tasks, & &1.node) == ["increment", "increment"]
    assert Enum.map(snapshot.tasks, & &1.path) == ["increment", "increment"]
    assert snapshot.channel_versions == %{"count" => 2}
    assert snapshot.versions_seen["increment"] == %{"count" => 1}
    assert snapshot.updated_channels == ["count"]
    assert [start_task, finish_task] = snapshot.tasks
    assert is_binary(start_task.id)
    assert start_task.id == finish_task.id

    history = Compiled.get_state_history(graph, config)
    assert Enum.any?(history, &(&1.values.count == 1))
    assert Enum.any?(history, &(&1.values.count == 2))

    assert Enum.any?(
             history,
             &(&1.metadata["source"] == "input" and &1.next == ["increment"] and
                 &1.updated_channels == [])
           )

    assert {:ok, updated_config} = Compiled.update_state(graph, config, %{count: 10})
    assert updated_config["configurable"]["checkpoint_id"]

    assert {:ok, updated_snapshot} = Compiled.get_state(graph, updated_config)

    assert updated_snapshot.parent_config["configurable"]["checkpoint_id"] ==
             snapshot.config["configurable"]["checkpoint_id"]

    assert updated_snapshot.channel_versions == %{"count" => 3}
    assert updated_snapshot.updated_channels == ["count"]

    assert {:ok, %{count: 11}} = Compiled.invoke(graph, %{}, config: config)
  end

  test "manual state updates preserve explicit nil values" do
    checkpointer = CheckpointETS.new()

    graph =
      Graph.new()
      |> Graph.add_node(:start, fn state -> state end)
      |> Graph.add_edge(Graph.start(), :start)
      |> Graph.add_edge(:start, Graph.end_node())
      |> Graph.compile!(checkpointer: checkpointer)

    config = %{"configurable" => %{"thread_id" => "nil-state-update"}}

    assert {:ok, %{value: "kept"}} = Compiled.invoke(graph, %{value: "kept"}, config: config)
    assert {:ok, update_config} = Compiled.update_state(graph, config, %{value: nil})
    assert {:ok, snapshot} = Compiled.get_state(graph, update_config)
    assert Map.has_key?(snapshot.values, :value)
    assert snapshot.values.value == nil
  end

  test "bulk state updates use channel-backed superstep merge semantics" do
    checkpointer = CheckpointETS.new()

    graph =
      Graph.new()
      |> Graph.add_reducer(:items, fn existing, update -> existing ++ List.wrap(update) end)
      |> Graph.add_node(:noop, fn state -> state end)
      |> Graph.add_edge(Graph.start(), :noop)
      |> Graph.add_edge(:noop, Graph.end_node())
      |> Graph.compile!(checkpointer: checkpointer)

    config = %{"configurable" => %{"thread_id" => "bulk"}}

    assert {:ok, final_config} =
             Compiled.bulk_update_state(graph, config, [
               [%{items: [:a]}, %{items: [:b]}],
               [%{answer: 42}]
             ])

    assert {:ok, snapshot} = Compiled.get_state(graph, final_config)
    assert snapshot.values.items == [:a, :b]
    assert snapshot.values.answer == 42
    assert snapshot.metadata["source"] == "update"
    assert snapshot.channel_versions == %{"answer" => 1, "items" => 1}
    assert snapshot.updated_channels == ["answer"]

    assert {:error, %Error{type: :invalid_update}} =
             Compiled.bulk_update_state(graph, final_config, [
               [%{answer: 1}, %{answer: 2}]
             ])
  end

  test "update_state infers continuation node while interrupted" do
    checkpointer = CheckpointETS.new()

    graph =
      Graph.new()
      |> Graph.add_node(:prepare, fn _state -> %{prepared: true} end)
      |> Graph.add_node(:finish, fn state -> %{finished: state.prepared and state.reviewed} end)
      |> Graph.add_edge(:prepare, :finish)
      |> Graph.add_edge(Graph.start(), :prepare)
      |> Graph.add_edge(:finish, Graph.end_node())
      |> Graph.compile!(checkpointer: checkpointer, interrupt_after: [:prepare])

    config = %{"configurable" => %{"thread_id" => "update-infer"}}

    assert {:interrupted, %{timing: :after, nodes: ["prepare"]}} =
             Compiled.invoke(graph, %{}, config: config)

    assert {:ok, update_config} = Compiled.update_state(graph, config, %{reviewed: true})
    assert {:ok, snapshot} = Compiled.get_state(graph, update_config)
    assert snapshot.next == ["finish"]

    assert {:ok, %{finished: true}} = Compiled.invoke(graph, %{}, config: update_config)
  end

  test "update_state can preserve interrupt pending writes and resume" do
    checkpointer = CheckpointETS.new()

    graph =
      Graph.new()
      |> Graph.add_node(:ask, fn state ->
        answer = Graph.interrupt(%{question: "continue?", note: Map.get(state, :note)})
        %{answer: answer, note: Map.get(state, :note)}
      end)
      |> Graph.add_edge(Graph.start(), :ask)
      |> Graph.add_edge(:ask, Graph.end_node())
      |> Graph.compile!(checkpointer: checkpointer)

    config = %{"configurable" => %{"thread_id" => "update-resume"}}

    assert {:interrupted, %{value: %{question: "continue?", note: nil}}} =
             Compiled.invoke(graph, %{}, config: config)

    assert {:ok, %{answer: "yes", note: "reviewed"}} =
             Compiled.update_state(graph, config, %{note: "reviewed"}, resume: "yes")
  end

  test "copied interrupted thread re-triggers interrupt on the sibling branch" do
    checkpointer = CheckpointETS.new()

    graph =
      Graph.new()
      |> Graph.add_node(:ask, fn _state ->
        answer = Graph.interrupt(%{question: "approve?"})
        %{answer: answer}
      end)
      |> Graph.add_edge(Graph.start(), :ask)
      |> Graph.add_edge(:ask, Graph.end_node())
      |> Graph.compile!(checkpointer: checkpointer)

    source_config = %{"configurable" => %{"thread_id" => "copy-interrupt-source"}}
    target_config = %{"configurable" => %{"thread_id" => "copy-interrupt-target"}}

    assert {:interrupted, source_interrupt} = Compiled.invoke(graph, %{}, config: source_config)

    assert :ok =
             BeamWeaver.Checkpoint.copy_thread(
               checkpointer,
               "copy-interrupt-source",
               "copy-interrupt-target"
             )

    assert {:interrupted, target_interrupt} = Compiled.invoke(graph, %{}, config: target_config)

    assert target_interrupt.value == source_interrupt.value
    assert target_interrupt.id == source_interrupt.id

    assert {:ok, %{answer: "source yes"}} =
             Compiled.resume(graph, %{source_interrupt.id => "source yes"}, config: source_config)

    assert {:ok, %{answer: "target yes"}} =
             Compiled.resume(graph, %{target_interrupt.id => "target yes"}, config: target_config)
  end

  test "failed supersteps persist successful task writes as pending writes" do
    parent = self()
    checkpointer = CheckpointETS.new()

    graph =
      Graph.new()
      |> Graph.add_node(:fanout, fn _state ->
        [
          %Send{node: :ok, update: %{value: "pending"}},
          %Send{node: :fail, update: %{attempt: 1}}
        ]
      end)
      |> Graph.add_node(:ok, fn state ->
        send(parent, :ok_ran)
        %{kept: state[:value]}
      end)
      |> Graph.add_node(:fail, fn state ->
        if state[:retry_ok],
          do: %{observed: "#{state[:kept]}:#{state[:attempt]}"},
          else: {:error, Error.new(:node_failed, "boom")}
      end)
      |> Graph.add_edge(Graph.start(), :fanout)
      |> Graph.add_edge(:ok, Graph.end_node())
      |> Graph.add_edge(:fail, Graph.end_node())
      |> Graph.compile!(checkpointer: checkpointer)

    config = %{"configurable" => %{"thread_id" => "pending-writes"}}

    assert {:error, %Error{type: :node_failed}} = Compiled.invoke(graph, %{}, config: config)
    assert_receive :ok_ran
    assert {:ok, snapshot} = Compiled.get_state(graph, config)

    assert snapshot.metadata["source"] == "loop"
    assert snapshot.values == %{kept: "pending"}
    assert snapshot.next == ["fail"]
    assert snapshot.next_tasks == [%{"node" => "fail", "update" => %{attempt: 1}}]

    assert {:ok, raw_snapshot} = Compiled.get_state(graph, snapshot.config)
    assert raw_snapshot.values == %{}

    assert raw_snapshot.next_tasks == [
             %{"node" => "ok", "update" => %{value: "pending"}},
             %{"node" => "fail", "update" => %{attempt: 1}}
           ]

    assert [{task_id, "kept", "pending"}] = data_writes(snapshot.pending_writes)
    assert is_binary(task_id)
    assert [{^task_id, "kept", task_path}] = data_write_paths(snapshot.pending_write_paths)

    assert BeamWeaver.JSON.decode!(task_path) == %{
             "node" => "ok",
             "update" => %{"value" => "pending"}
           }

    assert {:ok, %{observed: "pending:1"}} =
             Compiled.invoke(graph, %{retry_ok: true}, config: config)

    refute_receive :ok_ran, 50

    assert {:ok, restored} = Compiled.get_state(graph, config)
    assert restored.values.kept == "pending"
    assert restored.values.observed == "pending:1"
    assert restored.pending_writes == []
    assert restored.pending_write_paths == []
    assert restored.channel_versions["kept"] == 1
  end

  test "send timeout is checkpointed and replayed with pending writes" do
    parent = self()
    checkpointer = CheckpointETS.new()

    graph =
      Graph.new()
      |> Graph.add_node(:fanout, fn _state ->
        [
          %Send{node: :ok, update: %{value: "pending"}, timeout: 250},
          %Send{node: :fail, update: %{attempt: 1}}
        ]
      end)
      |> Graph.add_node(:ok, fn state ->
        send(parent, :timeout_ok_ran)
        %{kept: state[:value]}
      end)
      |> Graph.add_node(:fail, fn state ->
        if state[:retry_ok],
          do: %{observed: "#{state[:kept]}:#{state[:attempt]}"},
          else: {:error, Error.new(:node_failed, "boom")}
      end)
      |> Graph.add_edge(Graph.start(), :fanout)
      |> Graph.add_edge(:ok, Graph.end_node())
      |> Graph.add_edge(:fail, Graph.end_node())
      |> Graph.compile!(checkpointer: checkpointer)

    config = %{"configurable" => %{"thread_id" => "pending-writes-send-timeout"}}

    assert {:error, %Error{type: :node_failed}} = Compiled.invoke(graph, %{}, config: config)
    assert_receive :timeout_ok_ran

    assert {:ok, snapshot} = Compiled.get_state(graph, config)

    assert snapshot.next_tasks == [%{"node" => "fail", "update" => %{attempt: 1}}]

    assert {:ok, raw_snapshot} = Compiled.get_state(graph, snapshot.config)

    assert raw_snapshot.next_tasks == [
             %{"node" => "ok", "timeout" => 250, "update" => %{value: "pending"}},
             %{"node" => "fail", "update" => %{attempt: 1}}
           ]

    assert [{task_id, "kept", "pending"}] = data_writes(snapshot.pending_writes)
    assert [{^task_id, "kept", task_path}] = data_write_paths(snapshot.pending_write_paths)

    assert BeamWeaver.JSON.decode!(task_path) == %{
             "node" => "ok",
             "timeout" => 250,
             "update" => %{"value" => "pending"}
           }

    assert {:ok, %{observed: "pending:1"}} =
             Compiled.invoke(graph, %{retry_ok: true}, config: config)

    refute_receive :timeout_ok_ran, 50
  end

  test "proceed failure policy waits for siblings and persists their writes" do
    parent = self()
    checkpointer = CheckpointETS.new()

    graph =
      Graph.new()
      |> Graph.add_node(:fanout, fn _state ->
        [
          %Send{node: :fail},
          %Send{node: :slow_ok}
        ]
      end)
      |> Graph.add_node(:fail, fn state ->
        if state[:retry_ok],
          do: %{observed: state[:kept]},
          else: {:error, Error.new(:node_failed, "boom")}
      end)
      |> Graph.add_node(:slow_ok, fn _state ->
        Process.sleep(20)
        send(parent, :slow_ok_finished)
        %{kept: "from-proceed"}
      end)
      |> Graph.add_edge(Graph.start(), :fanout)
      |> Graph.add_edge(:fail, Graph.end_node())
      |> Graph.add_edge(:slow_ok, Graph.end_node())
      |> Graph.compile!(checkpointer: checkpointer, failure_policy: :proceed)

    config = %{"configurable" => %{"thread_id" => "proceed-pending-writes"}}

    assert {:error, %Error{type: :node_failed}} = Compiled.invoke(graph, %{}, config: config)
    assert_receive :slow_ok_finished, 100

    assert {:ok, snapshot} = Compiled.get_state(graph, config)
    assert [{task_id, "kept", "from-proceed"}] = data_writes(snapshot.pending_writes)
    assert [{^task_id, "kept", task_path}] = data_write_paths(snapshot.pending_write_paths)
    assert BeamWeaver.JSON.decode!(task_path) == %{"node" => "slow_ok", "update" => %{}}

    assert {:ok, %{observed: "from-proceed"}} =
             Compiled.invoke(graph, %{retry_ok: true}, config: config)

    refute_receive :slow_ok_finished, 50
  end

  defp data_writes(writes), do: Enum.reject(writes, &control_write?/1)
  defp data_write_paths(paths), do: Enum.reject(paths, &control_write?/1)

  defp control_write?({_task_id, "__error__", _value}), do: true
  defp control_write?({_task_id, "__interrupt__", _value}), do: true
  defp control_write?(_write), do: false

  test "stream_events emits typed graph updates and task metadata" do
    refute function_exported?(Compiled, :stream, 3)
    refute function_exported?(Compiled, :async_stream, 3)

    graph =
      Graph.new()
      |> Graph.add_node(:answer, fn _state -> %{answer: 42} end)
      |> Graph.add_edge(Graph.start(), :answer)
      |> Graph.add_edge(:answer, Graph.end_node())
      |> Graph.compile!()

    assert {:ok, events} = Compiled.stream_events(graph, %{})

    assert Enum.any?(
             events,
             &match?(%Envelope{event: %Events.Task{kind: :start, node: "answer"}}, &1)
           )

    assert Enum.any?(
             events,
             &match?(
               %Envelope{event: %Events.GraphUpdate{update: %{"answer" => %{answer: 42}}}},
               &1
             )
           )

    assert Enum.any?(events, &match?(%Envelope{event: %Events.Done{}}, &1))
  end

  test "streams custom events written from node runtime" do
    graph =
      Graph.new()
      |> Graph.add_node(:work, fn _state, runtime ->
        runtime.stream_writer.("first")
        runtime.stream_writer.(%{step: 2})
        %{answer: 42}
      end)
      |> Graph.add_edge(Graph.start(), :work)
      |> Graph.add_edge(:work, Graph.end_node())
      |> Graph.compile!()

    assert {:ok, events} = Compiled.stream_events(graph, %{})

    assert Enum.any?(events, &match?(%Envelope{event: %Events.Custom{payload: "first"}}, &1))
    assert Enum.any?(events, &match?(%Envelope{event: %Events.Custom{payload: %{step: 2}}}, &1))

    assert Enum.any?(
             events,
             &match?(
               %Envelope{event: %Events.GraphUpdate{update: %{"work" => %{answer: 42}}}},
               &1
             )
           )
  end

  test "streams message updates from graph nodes" do
    graph =
      Graph.new()
      |> Graph.add_node(:model, fn _state ->
        [
          Message.assistant("first"),
          Message.assistant("second")
        ]
      end)
      |> Graph.add_edge(Graph.start(), :model)
      |> Graph.add_edge(:model, Graph.end_node())
      |> Graph.compile!()

    assert {:ok, events} = Compiled.stream_events(graph, %{})

    assert events
           |> Enum.flat_map(fn
             %Envelope{event: %Events.Message{message: message}} -> [message.content]
             _event -> []
           end)
           |> Enum.take(2) == ["first", "second"]

    assert Enum.any?(
             events,
             &match?(%Envelope{event: %Events.Message{message: %Message{content: "first"}}}, &1)
           )

    assert Enum.any?(
             events,
             &match?(%Envelope{event: %Events.Message{message: %Message{content: "second"}}}, &1)
           )

    assert Enum.any?(
             events,
             &match?(
               %Envelope{
                 event: %Events.GraphUpdate{update: %{"model" => %{messages: [_first, _second]}}}
               },
               &1
             )
           )
  end

  test "stream_events returns typed envelopes with graph metadata" do
    graph =
      Graph.new(name: "TypedStreamGraph")
      |> Graph.add_node(:answer, fn _state -> %{answer: 42} end)
      |> Graph.add_edge(Graph.start(), :answer)
      |> Graph.add_edge(:answer, Graph.end_node())
      |> Graph.compile!()

    assert {:ok, events} = Compiled.stream_events(graph, %{})

    assert Enum.any?(
             events,
             &match?(
               %Envelope{
                 event: %Events.GraphUpdate{update: %{"answer" => %{answer: 42}}},
                 graph: "TypedStreamGraph",
                 step: _,
                 namespace: []
               },
               &1
             )
           )

    assert Enum.any?(
             events,
             &match?(
               %Envelope{
                 event: %Events.GraphValue{value: %{answer: 42}},
                 graph: "TypedStreamGraph",
                 namespace: []
               },
               &1
             )
           )
  end

  test "stream_events wraps typed graph events with lifecycle metadata" do
    graph =
      Graph.new(name: "LifecycleGraph")
      |> Graph.add_node(:answer, fn _state -> %{answer: 42} end)
      |> Graph.add_edge(Graph.start(), :answer)
      |> Graph.add_edge(:answer, Graph.end_node())
      |> Graph.compile!()

    assert {:ok, events} =
             Compiled.stream_events(graph, %{}, run_id: "run-1", metadata: %{source: :test})

    assert %Envelope{
             event: %Events.Debug{payload: %{type: :start, status: :running}},
             graph: "LifecycleGraph",
             run_id: "run-1",
             namespace: [],
             metadata: %{source: :test}
           } = hd(events)

    assert Enum.any?(
             events,
             &match?(
               %Envelope{
                 event: %Events.GraphUpdate{update: %{"answer" => %{answer: 42}}},
                 graph: "LifecycleGraph"
               },
               &1
             )
           )

    assert %Envelope{
             event: %Events.Done{result: %{status: :ok}},
             graph: "LifecycleGraph",
             run_id: "run-1",
             namespace: [],
             metadata: %{source: :test}
           } = List.last(events)

    assert {:ok, async_events} =
             graph
             |> Compiled.async_stream_events(%{}, run_id: "run-2")
             |> Async.await()

    assert Enum.any?(async_events, &match?(%Envelope{event: %Events.Done{}}, &1))
  end

  test "graph execution generates UUIDv7 run IDs by default" do
    graph =
      Graph.new(name: "GeneratedRunIdGraph")
      |> Graph.add_node(:answer, fn _state -> %{answer: 42} end)
      |> Graph.add_edge(Graph.start(), :answer)
      |> Graph.add_edge(:answer, Graph.end_node())
      |> Graph.compile!()

    assert {:ok, events} = Compiled.stream_events(graph, %{})

    run_id =
      events
      |> Enum.map(& &1.run_id)
      |> Enum.find(&is_binary/1)

    assert run_id =~ @uuidv7_regex
  end

  test "subgraph stream events keep child namespace metadata" do
    child =
      Graph.new(name: "ChildGraph")
      |> Graph.add_node(:child_node, fn _state -> %{child: true} end)
      |> Graph.add_edge(Graph.start(), :child_node)
      |> Graph.add_edge(:child_node, Graph.end_node())
      |> Graph.compile!()

    parent =
      Graph.new(name: "ParentGraph")
      |> Graph.add_node(:child, child)
      |> Graph.add_edge(Graph.start(), :child)
      |> Graph.add_edge(:child, Graph.end_node())
      |> Graph.compile!()

    assert {:ok, events} = Compiled.stream_events(parent, %{})

    assert Enum.any?(
             events,
             &match?(
               %Envelope{
                 event: %Events.GraphUpdate{update: %{"child_node" => %{child: true}}},
                 graph: "ChildGraph",
                 namespace: ["child"]
               },
               &1
             )
           )

    assert Enum.any?(
             events,
             &match?(
               %Envelope{
                 event: %Events.GraphUpdate{update: %{"child" => %{child: true}}},
                 graph: "ParentGraph",
                 namespace: []
               },
               &1
             )
           )
  end

  test "runtime push_message emits typed message events in messages and events streams" do
    pushed = Message.assistant("streamed", id: "msg-1")

    graph =
      Graph.new()
      |> Graph.add_node(:model, fn _state, runtime ->
        assert {:ok, ^pushed} = BeamWeaver.Graph.Runtime.push_message(runtime, pushed)
        %{messages: [pushed]}
      end)
      |> Graph.add_edge(Graph.start(), :model)
      |> Graph.add_edge(:model, Graph.end_node())
      |> Graph.compile!()

    assert {:ok, typed_events} = Compiled.stream_events(graph, %{})

    assert Enum.any?(
             typed_events,
             &match?(
               %Envelope{
                 event: %Events.Message{message: %Message{id: "msg-1", content: "streamed"}}
               },
               &1
             )
           )

    assert Enum.any?(
             typed_events,
             &match?(
               %Envelope{event: %Events.Message{message: %Message{id: "msg-1"}}},
               &1
             )
           )
  end

  test "live stream emits node events before the graph run completes" do
    parent = self()

    graph =
      Graph.new(name: "LiveGraph")
      |> Graph.add_node(:slow, fn _state, runtime ->
        runtime.stream_writer.(Stream.event(:custom, :before_sleep))
        send(parent, :node_emitted)
        Process.sleep(75)
        send(parent, :node_finished)
        %{answer: 42}
      end)
      |> Graph.add_edge(Graph.start(), :slow)
      |> Graph.add_edge(:slow, Graph.end_node())
      |> Graph.compile!()

    assert {:ok, stream} = Compiled.stream_events(graph, %{}, live: true)

    consumer =
      Task.async(fn ->
        Enum.each(stream, fn
          %Envelope{event: %Events.Custom{payload: :before_sleep}} ->
            send(parent, :consumer_saw_custom)

          _event ->
            :ok
        end)
      end)

    assert_receive :node_emitted, 200
    assert_receive :consumer_saw_custom, 200
    refute_receive :node_finished, 20
    assert_receive :node_finished, 300
    assert :ok = Task.await(consumer, 500)
  end

  test "halting a live graph stream cancels running node tasks" do
    graph =
      Graph.new(name: "CancelledLiveGraph")
      |> Graph.add_node(:slow, fn _state, runtime ->
        runtime.stream_writer.(Stream.event(:custom, {:node_pid, self()}))
        Process.sleep(:infinity)
        %{never: true}
      end)
      |> Graph.add_edge(Graph.start(), :slow)
      |> Graph.add_edge(:slow, Graph.end_node())
      |> Graph.compile!()

    assert {:ok, stream} = Compiled.stream_events(graph, %{}, live: true)

    %Envelope{event: %Events.Custom{payload: {:node_pid, node_pid}}} =
      Enum.find(stream, &match?(%Envelope{event: %Events.Custom{payload: {:node_pid, _}}}, &1))

    ref = Process.monitor(node_pid)
    assert_receive {:DOWN, ^ref, :process, ^node_pid, _reason}, 500
  end

  test "live graph streams emit typed interrupt debug events" do
    # Upstream reference:
    # langgraph/tests/test_stream_events_v3.py graph interrupt event coverage,
    # translated to BeamWeaver's typed event envelopes.
    graph =
      Graph.new(name: "LiveInterruptGraph")
      |> Graph.add_node(:approval, fn _state -> %{approved: true} end)
      |> Graph.add_edge(Graph.start(), :approval)
      |> Graph.add_edge(:approval, Graph.end_node())
      |> Graph.compile!(interrupt_before: [:approval])

    assert {:ok, stream} =
             Compiled.stream_events(graph, %{request: "delete"}, live: true)

    assert %Envelope{
             event: %Events.Debug{
               payload: %{type: :interrupt, interrupt: %{timing: :before, nodes: ["approval"]}}
             },
             graph: "LiveInterruptGraph",
             namespace: []
           } =
             Enum.find(stream, fn
               %Envelope{event: %Events.Debug{payload: %{type: :interrupt}}} -> true
               _event -> false
             end)
  end

  test "stream_events returns interrupted status and lifecycle envelopes" do
    graph =
      Graph.new(name: "InterruptedStreamGraph")
      |> Graph.add_node(:approval, fn _state -> %{approved: true} end)
      |> Graph.add_edge(Graph.start(), :approval)
      |> Graph.add_edge(:approval, Graph.end_node())
      |> Graph.compile!(interrupt_before: [:approval])

    assert {:interrupted, interrupt} =
             Compiled.stream_events(graph, %{request: "delete"},
               run_id: "run-interrupted",
               metadata: %{source: :test}
             )

    assert %{timing: :before, nodes: ["approval"], events: events} = interrupt

    assert %Envelope{
             event: %Events.Debug{payload: %{type: :start, status: :running}},
             graph: "InterruptedStreamGraph",
             run_id: "run-interrupted",
             metadata: %{source: :test}
           } = hd(events)

    assert %Envelope{
             event: %Events.Done{result: %{status: :interrupted}},
             graph: "InterruptedStreamGraph",
             run_id: "run-interrupted"
           } = List.last(events)
  end

  test "interrupts before configured nodes and returns resumable state" do
    graph =
      Graph.new()
      |> Graph.add_node(:approval, fn _state -> %{approved: true} end)
      |> Graph.add_edge(Graph.start(), :approval)
      |> Graph.add_edge(:approval, Graph.end_node())
      |> Graph.compile!(interrupt_before: [:approval])

    assert {:interrupted, interrupt} = Compiled.invoke(graph, %{request: "delete"})
    assert interrupt.timing == :before
    assert interrupt.nodes == ["approval"]
    assert interrupt.state == %{request: "delete"}
  end
end
