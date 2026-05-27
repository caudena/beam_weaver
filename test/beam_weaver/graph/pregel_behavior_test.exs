defmodule BeamWeaver.Graph.PregelBehaviorTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Checkpoint
  alias BeamWeaver.Checkpoint.ETS, as: CheckpointETS
  alias BeamWeaver.Core.Async
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Graph
  alias BeamWeaver.Graph.Channels.DeltaChannel
  alias BeamWeaver.Graph.Channels.Topic
  alias BeamWeaver.Graph.Command
  alias BeamWeaver.Graph.Compiled
  alias BeamWeaver.Graph.Execution.Scratchpad
  alias BeamWeaver.Graph.Send
  alias BeamWeaver.Stream.Envelope
  alias BeamWeaver.Stream.Events

  defmodule FaultySaver do
    @behaviour BeamWeaver.Checkpoint.Saver

    defstruct [:failure, :delegate]

    def new(failure),
      do: %__MODULE__{failure: failure, delegate: BeamWeaver.Checkpoint.ETS.new()}

    @impl true
    def get_tuple(%__MODULE__{failure: :get_tuple}, _config), do: raise("Faulty get_tuple")

    def get_tuple(%__MODULE__{delegate: delegate}, config),
      do: BeamWeaver.Checkpoint.ETS.get_tuple(delegate, config)

    @impl true
    def list(%__MODULE__{delegate: delegate}, config, opts),
      do: BeamWeaver.Checkpoint.ETS.list(delegate, config, opts)

    @impl true
    def put(%__MODULE__{failure: :put}, _config, _checkpoint, _metadata, _new_versions),
      do: {:error, "Faulty put"}

    def put(%__MODULE__{delegate: delegate}, config, checkpoint, metadata, new_versions),
      do: BeamWeaver.Checkpoint.ETS.put(delegate, config, checkpoint, metadata, new_versions)

    @impl true
    def put_writes(%__MODULE__{failure: :put_writes}, _config, _writes, _task_id, _task_path),
      do: {:error, "Faulty put_writes"}

    def put_writes(%__MODULE__{delegate: delegate}, config, writes, task_id, task_path),
      do: BeamWeaver.Checkpoint.ETS.put_writes(delegate, config, writes, task_id, task_path)

    @impl true
    def get_delta_channel_history(%__MODULE__{delegate: delegate}, config, channel_names, opts),
      do:
        BeamWeaver.Checkpoint.ETS.get_delta_channel_history(
          delegate,
          config,
          channel_names,
          opts
        )

    @impl true
    def delete_thread(%__MODULE__{delegate: delegate}, thread_id),
      do: BeamWeaver.Checkpoint.ETS.delete_thread(delegate, thread_id)

    @impl true
    def delete_for_runs(%__MODULE__{delegate: delegate}, run_ids),
      do: BeamWeaver.Checkpoint.ETS.delete_for_runs(delegate, run_ids)

    @impl true
    def copy_thread(%__MODULE__{delegate: delegate}, source_thread_id, target_thread_id),
      do: BeamWeaver.Checkpoint.ETS.copy_thread(delegate, source_thread_id, target_thread_id)

    @impl true
    def prune(%__MODULE__{delegate: delegate}, keep_run_ids, opts),
      do: BeamWeaver.Checkpoint.ETS.prune(delegate, keep_run_ids, opts)

    @impl true
    def next_version(%__MODULE__{failure: :next_version}, _current, _channel),
      do: raise("Faulty next_version")

    def next_version(%__MODULE__{delegate: delegate}, current, channel),
      do: BeamWeaver.Checkpoint.ETS.next_version(delegate, current, channel)
  end

  @moduledoc """
  Translated behavior coverage from LangGraph's Pregel tests.

  Source references:

  - `../langgraph/libs/langgraph/tests/test_pregel.py::test_pending_writes_resume`
  - `../langgraph/libs/langgraph/tests/test_pregel.py::test_invoke_two_processes_in_out`
  - `../langgraph/libs/checkpoint-conformance/.../test_put_writes.py::test_put_writes_task_path`
  - `../langgraph/libs/langgraph/tests/test_pregel.py::test_interrupt_multiple`
  - `../langgraph/libs/langgraph/tests/test_pregel.py::test_node_before_multiple_interrupt_cycles_graph_api`
  - `../langgraph/libs/langgraph/tests/test_pregel.py::test_double_interrupt_subgraph`
  - `../langgraph/libs/langgraph/tests/test_pregel.py::test_cond_edge_after_send`
  - `../langgraph/libs/langgraph/tests/test_pregel.py::test_fork_does_not_apply_pending_writes`
  - `../langgraph/libs/langgraph/tests/test_pregel.py::test_no_redundant_put_writes_for_cached_task`
  - `../langgraph/libs/langgraph/tests/test_pregel.py::test_send_sequences`
  - `../langgraph/libs/langgraph/tests/test_pregel.py::test_command_with_static_breakpoints`
  - `../langgraph/libs/langgraph/tests/test_pregel.py::test_parent_command_goto`
  - `../langgraph/libs/langgraph/tests/test_pregel.py::test_parent_command_goto_deeply_nested`
  - `../langgraph/libs/langgraph/langgraph/pregel/_retry.py::run_with_retry ParentCommand named namespace handling`
  - `../langgraph/libs/langgraph/tests/test_pregel.py::test_interrupt_subgraph`
  - `../langgraph/libs/langgraph/tests/test_pregel.py::test_subgraph_persistence`
  - `../langgraph/libs/langgraph/langgraph/pregel/main.py::get_state namespace delegation`
  - `../langgraph/libs/langgraph/tests/test_pregel.py::test_invoke_checkpoint_three`
  - `../langgraph/libs/langgraph/langgraph/pregel/_runner.py::PregelRunner.tick panic/proceed behavior`
  - `../langgraph/libs/langgraph/tests/test_pregel.py::test_run_from_checkpoint_id_retains_previous_writes`
  - `../langgraph/libs/langgraph/tests/test_pregel.py::test_invoke_two_processes_two_in_two_out_invalid`
  - `../langgraph/libs/langgraph/tests/test_pregel.py::test_invoke_two_processes_two_in_two_out_valid`
  - `../langgraph/libs/langgraph/tests/test_pregel.py::test_concurrent_emit_sends`
  - `../langgraph/libs/langgraph/tests/test_pregel.py::test_send_sequences`
  - `../langgraph/libs/langgraph/tests/test_pregel_async.py::test_batch_two_processes_in_out`
  - `../langgraph/libs/langgraph/tests/test_pregel_async.py::test_invoke_two_processes_two_in_two_out_invalid`
  - `../langgraph/libs/langgraph/tests/test_pregel_async.py::test_run_from_checkpoint_id_retains_previous_writes`
  - `../langgraph/libs/langgraph/tests/test_pregel_async.py::test_concurrent_emit_sends`
  - `../langgraph/libs/langgraph/tests/test_pregel_async.py::test_checkpoint_errors`
  """

  test "pending writes resume without rerunning completed sibling task" do
    parent = self()
    checkpointer = CheckpointETS.new()

    graph =
      Graph.new()
      |> Graph.add_reducer(:value, &+/2)
      |> Graph.add_node(:one, fn _state ->
        send(parent, :one_called)
        %{value: 2}
      end)
      |> Graph.add_node(:two, fn state ->
        send(parent, :two_called)

        if state[:two_ok],
          do: %{value: 3},
          else: {:error, Error.new(:connection_error, "I'm not good")}
      end)
      |> Graph.add_edge(Graph.start(), :one)
      |> Graph.add_edge(Graph.start(), :two)
      |> Graph.add_edge(:one, Graph.end_node())
      |> Graph.add_edge(:two, Graph.end_node())
      |> Graph.compile!(checkpointer: checkpointer)

    config = %{"configurable" => %{"thread_id" => "langgraph-pending-resume"}}

    assert {:error, %Error{type: :connection_error}} =
             Compiled.invoke(graph, %{value: 1}, config: config)

    assert_receive :one_called
    assert_receive :two_called

    assert {:ok, snapshot} = Compiled.get_state(graph, config)
    assert snapshot.values == %{value: 3}
    assert [{one_task_id, "value", 2}] = data_writes(snapshot.pending_writes)

    assert [{_two_task_id, "__error__", %Error{type: :connection_error}}] =
             error_writes(snapshot.pending_writes)

    assert snapshot.next == ["two"]
    assert is_binary(one_task_id)

    assert {:ok, raw_snapshot} = Compiled.get_state(graph, snapshot.config)
    assert raw_snapshot.values == %{value: 1}
    assert raw_snapshot.next == ["one", "two"]

    assert {:ok, %{value: 6}} = Compiled.invoke(graph, %{two_ok: true}, config: config)

    refute_receive :one_called, 50
    assert_receive :two_called

    assert {:ok, restored} = Compiled.get_state(graph, config)
    assert restored.pending_writes == []
    assert restored.values.value == 6
  end

  test "recursion limit prevents the next superstep from executing" do
    parent = self()

    graph =
      Graph.new()
      |> Graph.add_node(:one, fn state ->
        send(parent, {:ran, :one})
        %{value: Map.get(state, :value, 0) + 1}
      end)
      |> Graph.add_node(:two, fn state ->
        send(parent, {:ran, :two})
        %{value: state.value + 1}
      end)
      |> Graph.add_edge(:one, :two)
      |> Graph.add_edge(Graph.start(), :one)
      |> Graph.add_edge(:two, Graph.end_node())
      |> Graph.compile!(checkpointer: false)

    assert {:error, %Error{type: :recursion_limit, details: %{limit: 1, step: 1}}} =
             Compiled.invoke(graph, %{}, recursion_limit: 1)

    assert_receive {:ran, :one}
    refute_receive {:ran, :two}, 50
  end

  test "recursion limit propagates into subgraph execution" do
    parent_pid = self()

    child =
      Graph.new()
      |> Graph.add_node(:one, fn _state ->
        send(parent_pid, {:child_ran, :one})
        %{value: 1}
      end)
      |> Graph.add_node(:two, fn _state ->
        send(parent_pid, {:child_ran, :two})
        %{value: 2}
      end)
      |> Graph.add_edge(:one, :two)
      |> Graph.add_edge(Graph.start(), :one)
      |> Graph.add_edge(:two, Graph.end_node())
      |> Graph.compile!()

    parent =
      Graph.new()
      |> Graph.add_node(:child, child)
      |> Graph.add_edge(Graph.start(), :child)
      |> Graph.add_edge(:child, Graph.end_node())
      |> Graph.compile!()

    assert {:error, %Error{type: :recursion_limit, details: %{limit: 1, step: 1}}} =
             Compiled.invoke(parent, %{}, recursion_limit: 1)

    assert_receive {:child_ran, :one}
    refute_receive {:child_ran, :two}, 50
  end

  test "node tasks can run under a caller-provided task supervisor and still time out" do
    {:ok, supervisor} = Task.Supervisor.start_link()

    graph =
      Graph.new()
      |> Graph.add_node(
        :slow,
        fn _state ->
          Process.sleep(100)
          %{done: true}
        end,
        timeout: 10
      )
      |> Graph.add_edge(Graph.start(), :slow)
      |> Graph.add_edge(:slow, Graph.end_node())
      |> Graph.compile!()

    assert {:error, %Error{type: :node_timeout}} =
             Compiled.invoke(graph, %{}, task_supervisor: supervisor)

    Process.sleep(20)
    assert Task.Supervisor.children(supervisor) == []
  end

  test "compiled graph exposes Task-backed async event stream and batch-as-completed facades" do
    graph =
      Graph.new()
      |> Graph.add_node(:work, fn state ->
        Process.sleep(state.sleep_ms)
        %{value: state.value * 2}
      end)
      |> Graph.add_edge(Graph.start(), :work)
      |> Graph.add_edge(:work, Graph.end_node())
      |> Graph.compile!()

    assert {:ok, stream} =
             graph
             |> Compiled.async_stream_events(%{value: 1, sleep_ms: 0})
             |> Async.await()

    assert Enum.any?(
             stream,
             &match?(%Envelope{event: %Events.GraphUpdate{update: %{"work" => %{value: 2}}}}, &1)
           )

    assert {:ok, completion_stream} =
             Compiled.batch_as_completed(
               graph,
               [
                 %{value: 1, sleep_ms: 30},
                 %{value: 2, sleep_ms: 5}
               ],
               max_concurrency: 2
             )

    completions = Enum.to_list(completion_stream)
    assert elem(hd(completions), 0) == 1
    assert {0, {:ok, %{value: 2, sleep_ms: 30}}} in completions
    assert {1, {:ok, %{value: 4, sleep_ms: 5}}} in completions

    assert {:ok, async_completion_stream} =
             graph
             |> Compiled.async_batch_as_completed([%{value: 3, sleep_ms: 0}])
             |> Async.await()

    assert Enum.to_list(async_completion_stream) == [{0, {:ok, %{value: 6, sleep_ms: 0}}}]
  end

  test "checkpoint adapter failures surface through native runtime boundaries" do
    simple_graph = fn checkpointer ->
      Graph.new()
      |> Graph.add_node(:node, fn _state -> %{value: "ok"} end)
      |> Graph.add_edge(Graph.start(), :node)
      |> Graph.add_edge(:node, Graph.end_node())
      |> Graph.compile!(checkpointer: checkpointer)
    end

    assert_raise RuntimeError, "Faulty get_tuple", fn ->
      simple_graph.(FaultySaver.new(:get_tuple))
      |> Compiled.invoke(%{value: ""}, config: %{"configurable" => %{"thread_id" => "get"}})
    end

    assert {:error,
            %Error{
              type: :checkpoint_error,
              message: "checkpoint write failed",
              details: %{reason: "\"Faulty put\""}
            }} =
             simple_graph.(FaultySaver.new(:put))
             |> Compiled.invoke(%{value: ""},
               config: %{"configurable" => %{"thread_id" => "put"}}
             )

    assert_raise RuntimeError, "Faulty next_version", fn ->
      simple_graph.(FaultySaver.new(:next_version))
      |> Compiled.invoke(%{value: ""},
        config: %{"configurable" => %{"thread_id" => "next-version"}}
      )
    end

    graph =
      Graph.new()
      |> Graph.add_node(:fanout, fn _state ->
        [
          %Send{node: :ok, update: %{value: "pending"}},
          %Send{node: :fail}
        ]
      end)
      |> Graph.add_node(:ok, fn state -> %{kept: state.value} end)
      |> Graph.add_node(:fail, fn _state -> {:error, Error.new(:node_failed, "boom")} end)
      |> Graph.add_edge(Graph.start(), :fanout)
      |> Graph.add_edge(:ok, Graph.end_node())
      |> Graph.add_edge(:fail, Graph.end_node())
      |> Graph.compile!(checkpointer: FaultySaver.new(:put_writes))

    assert {:error,
            %Error{
              type: :checkpoint_error,
              message: "pending write persistence failed",
              details: %{reason: "\"Faulty put_writes\""}
            }} =
             Compiled.invoke(graph, %{}, config: %{"configurable" => %{"thread_id" => "put-writes"}})
  end

  test "Task-backed async checkpoint adapter failures surface through native boundaries" do
    simple_graph = fn checkpointer ->
      Graph.new()
      |> Graph.add_node(:node, fn _state -> %{value: "ok"} end)
      |> Graph.add_edge(Graph.start(), :node)
      |> Graph.add_edge(:node, Graph.end_node())
      |> Graph.compile!(checkpointer: checkpointer)
    end

    assert {:error, %Error{type: :checkpoint_error, message: "checkpoint write failed"}} =
             simple_graph.(FaultySaver.new(:put))
             |> Compiled.async_invoke(%{value: ""},
               config: %{"configurable" => %{"thread_id" => "async-put"}}
             )
             |> Async.await()

    assert {:error, %Error{type: :checkpoint_error, message: "checkpoint write failed"}} =
             simple_graph.(FaultySaver.new(:put))
             |> Compiled.async_stream_events(%{value: ""},
               config: %{"configurable" => %{"thread_id" => "async-stream-put"}}
             )
             |> Async.await()

    graph =
      Graph.new()
      |> Graph.add_node(:fanout, fn _state ->
        [
          %Send{node: :ok, update: %{value: "pending"}},
          %Send{node: :fail}
        ]
      end)
      |> Graph.add_node(:ok, fn state -> %{kept: state.value} end)
      |> Graph.add_node(:fail, fn _state -> {:error, Error.new(:node_failed, "boom")} end)
      |> Graph.add_edge(Graph.start(), :fanout)
      |> Graph.add_edge(:ok, Graph.end_node())
      |> Graph.add_edge(:fail, Graph.end_node())
      |> Graph.compile!(checkpointer: FaultySaver.new(:put_writes))

    assert {:error,
            %Error{
              type: :checkpoint_error,
              message: "pending write persistence failed"
            }} =
             graph
             |> Compiled.async_invoke(%{},
               config: %{"configurable" => %{"thread_id" => "async-put-writes"}}
             )
             |> Async.await()
  end

  test "parallel entry nodes execute in the same superstep" do
    graph =
      Graph.new()
      |> Graph.add_reducer(:results, fn existing, update -> existing ++ List.wrap(update) end)
      |> Graph.add_node(:slow, fn _state ->
        Process.sleep(75)
        %{results: ["slow"]}
      end)
      |> Graph.add_node(:fast, fn _state ->
        Process.sleep(75)
        %{results: ["fast"]}
      end)
      |> Graph.add_edge(Graph.start(), :slow)
      |> Graph.add_edge(Graph.start(), :fast)
      |> Graph.add_edge(:slow, Graph.end_node())
      |> Graph.add_edge(:fast, Graph.end_node())
      |> Graph.compile!()

    {duration_us, {:ok, %{results: results}}} =
      :timer.tc(fn -> Compiled.invoke(graph, %{results: []}) end)

    assert Enum.sort(results) == ["fast", "slow"]
    assert duration_us < 140_000
  end

  test "concurrent invocations of one compiled graph keep state independent" do
    graph =
      Graph.new()
      |> Graph.add_reducer(:counter, &+/2)
      |> Graph.add_node(:node, fn _state ->
        Process.sleep(25)
        %{counter: 1}
      end)
      |> Graph.add_edge(Graph.start(), :node)
      |> Graph.add_edge(:node, Graph.end_node())
      |> Graph.compile!()

    results =
      1..10
      |> Enum.map(fn _index -> Task.async(fn -> Compiled.invoke(graph, %{counter: 0}) end) end)
      |> Enum.map(&Task.await(&1, 1_000))

    assert Enum.all?(results, &(&1 == {:ok, %{counter: 1}}))
  end

  test "long linear graphs run repeatedly and concurrently with isolated state" do
    test_size = 25

    graph =
      0..(test_size - 1)
      |> Enum.reduce(
        Graph.new(input_schema: %{input: :integer}, output_schema: %{output: :integer}),
        fn index, graph ->
          node = "n#{index}"
          input_key = if index == 0, do: :input, else: :"n#{index - 1}"
          output_key = if index == test_size - 1, do: :output, else: :"n#{index}"

          graph
          |> Graph.add_node(
            node,
            fn state -> %{output_key => Map.fetch!(state, input_key) + 1} end,
            input: [input_key]
          )
          |> then(fn graph ->
            if index == 0 do
              Graph.add_edge(graph, Graph.start(), node)
            else
              Graph.add_edge(graph, "n#{index - 1}", node)
            end
          end)
        end
      )
      |> Graph.add_edge("n#{test_size - 1}", Graph.end_node())
      |> Graph.compile!()

    expected = 2 + test_size

    for _run <- 1..5 do
      assert {:ok, %{output: ^expected}} =
               Compiled.invoke(graph, %{input: 2}, recursion_limit: test_size + 1)
    end

    results =
      1..10
      |> Enum.map(fn _index ->
        Task.async(fn -> Compiled.invoke(graph, %{input: 2}, recursion_limit: test_size + 1) end)
      end)
      |> Enum.map(&Task.await(&1, 1_000))

    assert Enum.all?(results, &(&1 == {:ok, %{output: expected}}))

    assert Compiled.batch(
             graph,
             [%{input: 2}, %{input: 1}, %{input: 3}],
             recursion_limit: test_size + 1
           ) == [
             {:ok, %{output: 2 + test_size}},
             {:ok, %{output: 1 + test_size}},
             {:ok, %{output: 3 + test_size}}
           ]
  end

  test "same-superstep last-value writes fail unless the channel accumulates" do
    invalid =
      Graph.new(output_schema: %{hello: :string})
      |> Graph.add_node(:one, fn _state -> %{hello: "world"} end)
      |> Graph.add_node(:two, fn _state -> %{hello: "there"} end)
      |> Graph.add_edge(Graph.start(), :one)
      |> Graph.add_edge(Graph.start(), :two)
      |> Graph.add_edge(:one, Graph.end_node())
      |> Graph.add_edge(:two, Graph.end_node())
      |> Graph.compile!()

    assert {:error,
            %Error{
              type: :invalid_update,
              message: "last-value channel can receive only one value per step",
              details: %{channel: :hello}
            }} = Compiled.invoke(invalid, %{})

    valid =
      Graph.new(output_schema: %{output: :list})
      |> Graph.add_channel(:output, Topic.new())
      |> Graph.add_node(:one, fn state -> %{output: Map.fetch!(state, :input) + 1} end)
      |> Graph.add_node(:two, fn state -> %{output: Map.fetch!(state, :input) + 1} end)
      |> Graph.add_edge(Graph.start(), :one)
      |> Graph.add_edge(Graph.start(), :two)
      |> Graph.add_edge(:one, Graph.end_node())
      |> Graph.add_edge(:two, Graph.end_node())
      |> Graph.compile!()

    assert {:ok, %{output: outputs}} = Compiled.invoke(valid, %{input: 2})
    assert Enum.sort(outputs) == [3, 3]
  end

  test "running from checkpoint id writes a fork checkpoint and preserves history" do
    checkpointer = CheckpointETS.new()
    {:ok, toggle} = Agent.start_link(fn -> false end)

    node = fn _state ->
      {value, switched?} =
        Agent.get_and_update(toggle, fn previous ->
          switched? = not previous
          {{if(switched?, do: 2, else: 1), switched?}, switched?}
        end)

      %{myval: value, otherval: switched?}
    end

    graph =
      Graph.new()
      |> Graph.add_reducer(:myval, &+/2)
      |> Graph.add_node(:node_one, node)
      |> Graph.add_node(:node_two, node)
      |> Graph.add_edge(Graph.start(), :node_one)
      |> Graph.add_edge(:node_one, :node_two, when: fn _output, state -> state.myval <= 3 and state.otherval end)
      |> Graph.add_edge(:node_one, :node_one, when: fn _output, state -> state.myval <= 3 and not state.otherval end)
      |> Graph.add_edge(:node_two, :node_one, when: fn _output, state -> state.myval <= 3 and state.otherval end)
      |> Graph.add_edge(:node_two, :node_two, when: fn _output, state -> state.myval <= 3 and not state.otherval end)
      |> Graph.add_edge(:node_one, Graph.end_node(), when: fn _output, state -> state.myval > 3 end)
      |> Graph.add_edge(:node_two, Graph.end_node(), when: fn _output, state -> state.myval > 3 end)
      |> Graph.compile!(checkpointer: checkpointer)

    config = %{"configurable" => %{"thread_id" => "langgraph-run-from-checkpoint"}}

    assert {:ok, %{myval: 4, otherval: false}} =
             Compiled.invoke(graph, %{myval: 1}, config: config, recursion_limit: 10)

    history = Compiled.get_state_history(graph, config)

    assert Enum.map(history, & &1.values) == [
             %{myval: 4, otherval: false},
             %{myval: 3, otherval: true},
             %{myval: 1}
           ]

    fork_source = Enum.at(history, 1)

    assert {:ok, %{myval: 5, otherval: true}} =
             Compiled.invoke(graph, %{}, config: fork_source.config, recursion_limit: 10)

    [new_result, fork | copied_history] = Compiled.get_state_history(graph, config)

    assert fork.metadata["source"] == "fork"
    assert fork.values == fork_source.values
    assert fork.next == fork_source.next

    assert new_result.parent_config["configurable"]["checkpoint_id"] ==
             fork.config["configurable"]["checkpoint_id"]

    assert Enum.map(copied_history, &{&1.values, &1.next, &1.metadata["step"]}) ==
             Enum.map(history, &{&1.values, &1.next, &1.metadata["step"]})
  end

  test "conditional routers can emit sends concurrently with branch routes" do
    node = fn name ->
      fn state ->
        update =
          if Map.has_key?(state, :item),
            do: ["#{name}|#{state.item}"],
            else: [to_string(name)]

        %{log: update}
      end
    end

    branch_one = fn _state ->
      [
        %{log: ["1"]},
        %Send{node: :"2", update: %{item: 1}},
        %Send{node: :"2", update: %{item: 2}},
        %Command{goto: :"3.1"}
      ]
    end

    branch_one_one = fn _state ->
      [
        %{log: ["1.1"]},
        %Send{node: :"2", update: %{item: 3}},
        %Send{node: :"2", update: %{item: 4}}
      ]
    end

    graph =
      Graph.new(output_schema: %{log: :list})
      |> Graph.add_reducer(:log, fn existing, update -> existing ++ List.wrap(update) end)
      |> Graph.add_node(:"1", branch_one)
      |> Graph.add_node(:"1.1", branch_one_one)
      |> Graph.add_node(:"2", node.("2"))
      |> Graph.add_node(:"3", node.("3"))
      |> Graph.add_node(:"3.1", node.("3.1"))
      |> Graph.add_edge(Graph.start(), :"1")
      |> Graph.add_edge(Graph.start(), :"1.1")
      |> Graph.add_edge(:"2", :"3")
      |> Graph.compile!()

    assert {:ok,
            %{
              log: [
                "0",
                "1",
                "1.1",
                "3.1",
                "2|1",
                "2|2",
                "2|3",
                "2|4",
                "3"
              ]
            }} = Compiled.invoke(graph, %{log: ["0"]}, recursion_limit: 10)
  end

  test "send payloads can carry commands that schedule additional sends" do
    node = fn name ->
      fn
        %BeamWeaver.Graph.Command{goto: %Send{update: item}} = command ->
          [
            command,
            %BeamWeaver.Graph.Command{update: %{log: ["#{name}|command:#{item}"]}}
          ]

        item when is_integer(item) ->
          %{log: ["#{name}|#{item}"]}

        _state ->
          %{log: [to_string(name)]}
      end
    end

    graph =
      Graph.new(output_schema: %{log: :list})
      |> Graph.add_reducer(:log, fn existing, update -> existing ++ List.wrap(update) end)
      |> Graph.add_node(:"1", fn _state ->
        [
          %{log: ["1"]},
          %Send{
            node: :"2",
            update: %BeamWeaver.Graph.Command{goto: %Send{node: :"2", update: 3}}
          },
          %Send{
            node: :"2",
            update: %BeamWeaver.Graph.Command{goto: %Send{node: :"2", update: 4}}
          },
          %Command{goto: :"3.1"}
        ]
      end)
      |> Graph.add_node(:"2", node.("2"))
      |> Graph.add_node(:"3", node.("3"))
      |> Graph.add_node(:"3.1", node.("3.1"))
      |> Graph.add_edge(Graph.start(), :"1")
      |> Graph.add_edge(:"2", :"3")
      |> Graph.compile!()

    assert {:ok,
            %{
              log: [
                "0",
                "1",
                "3.1",
                "2|command:3",
                "2|command:4",
                "3",
                "2|3",
                "2|4",
                "3"
              ]
            }} = Compiled.invoke(graph, %{log: ["0"]}, recursion_limit: 10)
  end

  test "checkpointed runs retry transient node errors and preserve checkpoint on terminal error" do
    checkpointer = CheckpointETS.new()
    {:ok, errored_once?} = Agent.start_link(fn -> false end)

    node = fn state ->
      output = Map.get(state, :total, 0) + Map.fetch!(state, :input)

      if output > 4 do
        first_error? =
          Agent.get_and_update(errored_once?, fn
            false -> {true, true}
            true -> {false, true}
          end)

        if first_error?, do: raise("I will be retried")
      end

      if output > 10, do: raise("Input is too large")

      %{output: output, total: output}
    end

    graph =
      Graph.new(output_schema: %{output: :integer})
      |> Graph.add_reducer(:total, &+/2)
      |> Graph.add_node(:one, node, retry: BeamWeaver.RetryPolicy.new!(max_attempts: 2))
      |> Graph.add_edge(Graph.start(), :one)
      |> Graph.add_edge(:one, Graph.end_node())
      |> Graph.compile!(checkpointer: checkpointer)

    thread_one = %{"configurable" => %{"thread_id" => "langgraph-checkpoint-two-1"}}
    thread_two = %{"configurable" => %{"thread_id" => "langgraph-checkpoint-two-2"}}

    assert {:ok, %{output: 2}} = Compiled.invoke(graph, %{input: 2}, config: thread_one)

    assert %{checkpoint: %{"channel_values" => first_values}} =
             Checkpoint.get_tuple(checkpointer, thread_one)

    assert first_values.total == 2

    assert {:ok, %{output: 5}} = Compiled.invoke(graph, %{input: 3}, config: thread_one)
    assert Agent.get(errored_once?, & &1)

    assert %{checkpoint: %{"channel_values" => second_values}} =
             Checkpoint.get_tuple(checkpointer, thread_one)

    assert second_values.total == 7

    assert {:error, %Error{type: :node_exception, message: "Input is too large"}} =
             Compiled.invoke(graph, %{input: 4}, config: thread_one)

    assert %{checkpoint: %{"channel_values" => after_error_values}, pending_writes: writes} =
             Checkpoint.get_tuple(checkpointer, thread_one)

    assert after_error_values.total == 7

    assert [{_task_id, "__error__", %Error{type: :node_exception, message: "Input is too large"}}] =
             error_writes(writes)

    assert {:ok, %{output: 5}} = Compiled.invoke(graph, %{input: 5}, config: thread_two)

    assert %{checkpoint: %{"channel_values" => thread_one_values}} =
             Checkpoint.get_tuple(checkpointer, thread_one)

    assert %{checkpoint: %{"channel_values" => thread_two_values}} =
             Checkpoint.get_tuple(checkpointer, thread_two)

    assert thread_one_values.total == 7
    assert thread_two_values.total == 5
  end

  test "Task-backed async facade preserves batch, invalid update, fork, and send behavior" do
    chain =
      Graph.new(input_schema: %{input: :integer}, output_schema: %{output: :integer})
      |> Graph.add_node(:one, fn state -> %{one: state.input + 1} end, input: [:input])
      |> Graph.add_node(:two, fn state -> %{output: state.one + 1} end, input: [:one])
      |> Graph.add_edge(Graph.start(), :one)
      |> Graph.add_edge(:one, :two)
      |> Graph.add_edge(:two, Graph.end_node())
      |> Graph.compile!()

    assert [
             {:ok, %{output: 5}},
             {:ok, %{output: 4}},
             {:ok, %{output: 3}}
           ] =
             chain
             |> Compiled.async_batch([%{input: 3}, %{input: 2}, %{input: 1}])
             |> Async.await_batch()

    invalid =
      Graph.new(output_schema: %{hello: :string})
      |> Graph.add_node(:one, fn _state -> %{hello: "world"} end)
      |> Graph.add_node(:two, fn _state -> %{hello: "there"} end)
      |> Graph.add_edge(Graph.start(), :one)
      |> Graph.add_edge(Graph.start(), :two)
      |> Graph.add_edge(:one, Graph.end_node())
      |> Graph.add_edge(:two, Graph.end_node())
      |> Graph.compile!()

    assert {:error, %Error{type: :invalid_update}} =
             invalid
             |> Compiled.async_invoke(%{})
             |> Async.await()

    checkpointer = CheckpointETS.new()

    checkpointed =
      Graph.new()
      |> Graph.add_reducer(:count, &+/2)
      |> Graph.add_node(:one, fn _state -> %{count: 1} end)
      |> Graph.add_node(:two, fn _state -> %{count: 2} end)
      |> Graph.add_edge(Graph.start(), :one)
      |> Graph.add_edge(:one, :two)
      |> Graph.add_edge(:two, Graph.end_node())
      |> Graph.compile!(checkpointer: checkpointer)

    config = %{"configurable" => %{"thread_id" => "langgraph-async-fork"}}

    assert {:ok, %{count: 3}} =
             checkpointed
             |> Compiled.async_invoke(%{count: 0}, config: config)
             |> Async.await()

    [_final, fork_source | _rest] = Compiled.get_state_history(checkpointed, config)

    assert {:ok, %{count: 3}} =
             checkpointed
             |> Compiled.async_invoke(%{}, config: fork_source.config)
             |> Async.await()

    [_new_result, fork | _copied] = Compiled.get_state_history(checkpointed, config)
    assert fork.metadata["source"] == "fork"
    assert fork.values == fork_source.values

    sends =
      Graph.new(output_schema: %{log: :list})
      |> Graph.add_reducer(:log, fn existing, update -> existing ++ List.wrap(update) end)
      |> Graph.add_node(:start, fn _state ->
        [
          %{log: ["start"]},
          %Send{node: :sent, update: %{item: 1}},
          %Command{goto: :route}
        ]
      end)
      |> Graph.add_node(:sent, fn state -> %{log: ["sent:#{state.item}"]} end)
      |> Graph.add_node(:route, fn _state -> %{log: ["route"]} end)
      |> Graph.add_edge(Graph.start(), :start)
      |> Graph.compile!()

    assert {:ok, %{log: ["0", "start", "route", "sent:1"]}} =
             sends
             |> Compiled.async_invoke(%{log: ["0"]}, recursion_limit: 5)
             |> Async.await()
  end

  test "Task-backed async state APIs replay and fork from interrupt checkpoints" do
    checkpointer = CheckpointETS.new()

    graph =
      Graph.new()
      |> Graph.add_reducer(:value, fn existing, update ->
        List.wrap(existing) ++ List.wrap(update)
      end)
      |> Graph.add_node(:node_a, fn _state -> %{value: ["a"]} end)
      |> Graph.add_node(:ask, fn _state ->
        answer = Graph.interrupt("What is your input?")
        %{value: ["human:#{answer}"]}
      end)
      |> Graph.add_node(:node_b, fn _state -> %{value: ["b"]} end)
      |> Graph.add_edge(Graph.start(), :node_a)
      |> Graph.add_edge(:node_a, :ask)
      |> Graph.add_edge(:ask, :node_b)
      |> Graph.add_edge(:node_b, Graph.end_node())
      |> Graph.compile!(checkpointer: checkpointer)

    config = %{"configurable" => %{"thread_id" => "langgraph-async-time-travel"}}

    assert {:interrupted, first_interrupt} =
             graph
             |> Compiled.async_invoke(%{value: []}, config: config)
             |> Async.await()

    assert first_interrupt.value == "What is your input?"

    history =
      graph
      |> Compiled.async_get_state_history(config)
      |> Async.await()

    before_ask = Enum.find(history, &(&1.next == ["ask"]))

    assert {:interrupted, replay_interrupt} =
             graph
             |> Compiled.async_invoke(%{}, config: before_ask.config)
             |> Async.await()

    assert replay_interrupt.value == first_interrupt.value

    assert {:ok, fork_config} =
             graph
             |> Compiled.async_update_state(before_ask.config, %{value: ["fork"]})
             |> Async.await()

    assert {:ok, fork_snapshot} =
             graph
             |> Compiled.async_get_state(fork_config)
             |> Async.await()

    assert fork_snapshot.values.value == ["a", "fork"]
    assert fork_snapshot.next == ["ask"]
    assert fork_snapshot.metadata["source"] == "update"

    assert {:interrupted, fork_interrupt} =
             graph
             |> Compiled.async_invoke(%{}, config: fork_config)
             |> Async.await()

    assert fork_interrupt.value == "What is your input?"

    assert {:ok, %{value: ["a", "fork", "human:yes", "b"]}} =
             graph
             |> Compiled.async_resume("yes", config: fork_interrupt.config)
             |> Async.await()
  end

  test "send task paths preserve payloads through pending write replay" do
    parent = self()
    checkpointer = CheckpointETS.new()

    graph =
      Graph.new()
      |> Graph.add_node(:fanout, fn _state ->
        [
          %Send{node: :done, update: %{payload: "kept"}},
          %Send{node: :fail, update: %{attempt: 1}}
        ]
      end)
      |> Graph.add_node(:done, fn state ->
        send(parent, :done_called)
        %{kept: state.payload}
      end)
      |> Graph.add_node(:fail, fn state ->
        if state[:retry_ok],
          do: %{observed: "#{state.kept}:#{state.attempt}"},
          else: {:error, Error.new(:node_failed, "boom")}
      end)
      |> Graph.add_edge(Graph.start(), :fanout)
      |> Graph.add_edge(:done, Graph.end_node())
      |> Graph.add_edge(:fail, Graph.end_node())
      |> Graph.compile!(checkpointer: checkpointer)

    config = %{"configurable" => %{"thread_id" => "langgraph-send-task-path"}}

    assert {:error, %Error{type: :node_failed}} = Compiled.invoke(graph, %{}, config: config)
    assert_receive :done_called

    assert {:ok, snapshot} = Compiled.get_state(graph, config)
    assert [{task_id, "kept", "kept"}] = data_writes(snapshot.pending_writes)

    assert [{_fail_task_id, "__error__", %Error{type: :node_failed}}] =
             error_writes(snapshot.pending_writes)

    assert [{^task_id, "kept", task_path}] = data_write_paths(snapshot.pending_write_paths)

    assert BeamWeaver.JSON.decode!(task_path) == %{
             "node" => "done",
             "update" => %{"payload" => "kept"}
           }

    assert {:ok, %{observed: "kept:1"}} =
             Compiled.invoke(graph, %{retry_ok: true}, config: config)

    refute_receive :done_called, 50
  end

  test "node interrupt persists checkpoint and resumes with scalar value" do
    checkpointer = CheckpointETS.new()

    graph =
      Graph.new()
      |> Graph.add_reducer(:log, fn existing, update -> existing ++ List.wrap(update) end)
      |> Graph.add_node(:ask, fn state ->
        answer = Graph.interrupt(%{question: "approve?"})
        %{answer: answer, log: ["answered:#{answer}:#{state.request}"]}
      end)
      |> Graph.add_edge(Graph.start(), :ask)
      |> Graph.add_edge(:ask, Graph.end_node())
      |> Graph.compile!(checkpointer: checkpointer)

    config = %{"configurable" => %{"thread_id" => "langgraph-interrupt-resume"}}

    assert {:interrupted, interrupt} =
             Compiled.invoke(graph, %{request: "deploy", log: []}, config: config)

    assert interrupt.value == %{question: "approve?"}
    assert interrupt.nodes == ["ask"]
    assert is_binary(interrupt.id)

    assert {:ok, snapshot} = Compiled.get_state(graph, config)
    assert [pending_interrupt] = snapshot.interrupts
    assert pending_interrupt.id == interrupt.id
    assert snapshot.next == ["ask"]

    assert {:ok, %{answer: "yes", log: ["answered:yes:deploy"], request: "deploy"}} =
             Compiled.resume(graph, "yes", config: config)
  end

  test "resume map can target an interrupted task" do
    checkpointer = CheckpointETS.new()

    graph =
      Graph.new()
      |> Graph.add_node(:ask, fn _state ->
        answer = Graph.interrupt("name?")
        %{name: answer}
      end)
      |> Graph.add_edge(Graph.start(), :ask)
      |> Graph.add_edge(:ask, Graph.end_node())
      |> Graph.compile!(checkpointer: checkpointer)

    config = %{"configurable" => %{"thread_id" => "langgraph-interrupt-map-resume"}}

    assert {:interrupted, interrupt} = Compiled.invoke(graph, %{}, config: config)

    assert {:ok, %{name: "Ada"}} =
             Compiled.resume(graph, %{interrupt.id => "Ada"}, config: config)
  end

  test "parallel interrupts require map resume and resume by interrupt id" do
    checkpointer = CheckpointETS.new()

    graph =
      Graph.new()
      |> Graph.add_reducer(:answers, fn existing, update -> existing ++ List.wrap(update) end)
      |> Graph.add_node(:left, fn _state ->
        answer = Graph.interrupt("left?")
        %{answers: ["left:#{answer}"]}
      end)
      |> Graph.add_node(:right, fn _state ->
        answer = Graph.interrupt("right?")
        %{answers: ["right:#{answer}"]}
      end)
      |> Graph.add_edge(Graph.start(), :left)
      |> Graph.add_edge(Graph.start(), :right)
      |> Graph.add_edge(:left, Graph.end_node())
      |> Graph.add_edge(:right, Graph.end_node())
      |> Graph.compile!(checkpointer: checkpointer)

    config = %{"configurable" => %{"thread_id" => "langgraph-parallel-interrupt-map-resume"}}

    assert {:interrupted, _interrupt} = Compiled.invoke(graph, %{answers: []}, config: config)
    assert {:ok, snapshot} = Compiled.get_state(graph, config)
    assert [first, second] = Enum.sort_by(snapshot.interrupts, & &1.node)

    assert {:error, %Error{type: :invalid_resume}} =
             Compiled.resume(graph, "same-answer", config: config)

    assert {:ok, %{answers: answers}} =
             Compiled.resume(graph, %{first.id => "A", second.id => "B"}, config: config)

    assert Enum.sort(answers) == ["left:A", "right:B"]
  end

  test "explicit null resume returns nil to interrupted node" do
    checkpointer = CheckpointETS.new()

    graph =
      Graph.new()
      |> Graph.add_node(:ask, fn _state ->
        answer = Graph.interrupt("optional?")
        %{answer: answer}
      end)
      |> Graph.add_edge(Graph.start(), :ask)
      |> Graph.add_edge(:ask, Graph.end_node())
      |> Graph.compile!(checkpointer: checkpointer)

    config = %{"configurable" => %{"thread_id" => "langgraph-null-resume"}}

    assert {:interrupted, _interrupt} = Compiled.invoke(graph, %{}, config: config)
    assert {:ok, %{answer: nil}} = Compiled.resume(graph, Graph.null_resume(), config: config)
  end

  test "sequential interrupts remember prior resume values across re-entry" do
    checkpointer = CheckpointETS.new()

    graph =
      Graph.new()
      |> Graph.add_node(:prepare, fn state -> %{count: state.count + 10} end)
      |> Graph.add_node(:ask, fn _state ->
        first = Graph.interrupt("First question?")
        second = Graph.interrupt("Second question?")
        %{data: "#{first},#{second}"}
      end)
      |> Graph.add_edge(:prepare, :ask)
      |> Graph.add_edge(Graph.start(), :prepare)
      |> Graph.add_edge(:ask, Graph.end_node())
      |> Graph.compile!(checkpointer: checkpointer)

    config = %{"configurable" => %{"thread_id" => "langgraph-sequential-interrupt-reentry"}}

    assert {:interrupted, first} = Compiled.invoke(graph, %{count: 0}, config: config)
    assert first.value == "First question?"

    assert {:interrupted, second} = Compiled.resume(graph, "first_answer", config: config)
    assert second.value == "Second question?"
    assert second.id != first.id

    assert {:ok, %{count: 10, data: "first_answer,second_answer"}} =
             Compiled.resume(graph, "second_answer", config: config)
  end

  test "parent graph resume reaches interrupted subgraph task" do
    checkpointer = CheckpointETS.new()

    child =
      Graph.new()
      |> Graph.add_node(:bar, fn _state ->
        value = Graph.interrupt("Please provide baz value:")
        %{baz: value}
      end)
      |> Graph.add_edge(Graph.start(), :bar)
      |> Graph.add_edge(:bar, Graph.end_node())
      |> Graph.compile!()

    parent =
      Graph.new()
      |> Graph.add_node(:foo, fn _state -> %{baz: "foo"} end)
      |> Graph.add_node(:bar, child)
      |> Graph.add_edge(:foo, :bar)
      |> Graph.add_edge(Graph.start(), :foo)
      |> Graph.add_edge(:bar, Graph.end_node())
      |> Graph.compile!(checkpointer: checkpointer)

    config = %{"configurable" => %{"thread_id" => "langgraph-subgraph-interrupt-resume"}}

    assert {:interrupted, interrupt} = Compiled.invoke(parent, %{baz: ""}, config: config)
    assert interrupt.value == "Please provide baz value:"

    assert {:ok, snapshot} = Compiled.get_state(parent, config)
    assert [pending_interrupt] = snapshot.interrupts
    assert pending_interrupt.id == interrupt.id
    assert snapshot.next == ["bar"]

    assert {:ok, %{baz: "bar"}} =
             Compiled.resume(parent, %{pending_interrupt.id => "bar"}, config: config)
  end

  test "parent graph re-enters subgraph with sequential interrupts" do
    checkpointer = CheckpointETS.new()

    child =
      Graph.new()
      |> Graph.add_node(:node_1, fn _state ->
        result = Graph.interrupt("interrupt node 1")
        %{input: result}
      end)
      |> Graph.add_node(:node_2, fn _state ->
        result = Graph.interrupt("interrupt node 2")
        %{input: result}
      end)
      |> Graph.add_edge(:node_1, :node_2)
      |> Graph.add_edge(Graph.start(), :node_1)
      |> Graph.add_edge(:node_2, Graph.end_node())
      |> Graph.compile!()

    parent =
      Graph.new()
      |> Graph.add_node(:invoke_sub_agent, child)
      |> Graph.add_edge(Graph.start(), :invoke_sub_agent)
      |> Graph.add_edge(:invoke_sub_agent, Graph.end_node())
      |> Graph.compile!(checkpointer: checkpointer)

    config = %{"configurable" => %{"thread_id" => "langgraph-double-interrupt-subgraph"}}

    assert {:interrupted, first} = Compiled.invoke(parent, %{input: "test"}, config: config)
    assert first.value == "interrupt node 1"

    assert {:interrupted, second} =
             Compiled.resume(parent, %{first.id => "first"}, config: config)

    assert second.value == "interrupt node 2"
    assert second.id != first.id

    assert {:ok, %{input: "second"}} =
             Compiled.resume(parent, %{second.id => "second"}, config: config)
  end

  test "conditional edge after send sees reducer-merged send results" do
    graph =
      Graph.new()
      |> Graph.add_reducer(:items, fn existing, update -> existing ++ List.wrap(update) end)
      |> Graph.add_node(:fanout, fn _state ->
        [
          %Send{node: :worker, update: %{item: :a}},
          %Send{node: :worker, update: %{item: :b}}
        ]
      end)
      |> Graph.add_node(:worker, fn state -> %{items: [state.item]} end)
      |> Graph.add_node(:done, fn state -> %{done: Enum.sort(state.items)} end)
      |> Graph.add_edge(:worker, :done, when: fn _output, state -> Enum.sort(state.items) == [:a, :b] end)
      |> Graph.add_edge(Graph.start(), :fanout)
      |> Graph.add_edge(:done, Graph.end_node())
      |> Graph.compile!()

    assert {:ok, %{done: [:a, :b]}} = Compiled.invoke(graph, %{items: []})
  end

  test "command goto send schedules push task with command update" do
    graph =
      Graph.new()
      |> Graph.add_reducer(:items, fn existing, update -> existing ++ List.wrap(update) end)
      |> Graph.add_node(:start, fn _state ->
        %BeamWeaver.Graph.Command{
          update: %{items: [:start]},
          goto: %Send{node: :worker, update: %{item: :from_command}}
        }
      end)
      |> Graph.add_node(:worker, fn state -> %{items: [state.item]} end)
      |> Graph.add_edge(Graph.start(), :start)
      |> Graph.add_edge(:worker, Graph.end_node())
      |> Graph.compile!()

    assert {:ok, %{items: [:start, :from_command]}} = Compiled.invoke(graph, %{items: []})
  end

  test "command input goto resumes from checkpoint and adds branch task" do
    checkpointer = CheckpointETS.new()

    graph =
      Graph.new()
      |> Graph.add_reducer(:foo, &<>/2)
      |> Graph.add_node(:node1, fn _state -> %{foo: "|node-1"} end)
      |> Graph.add_node(:node2, fn _state -> %{foo: "|node-2"} end)
      |> Graph.add_edge(:node1, :node2)
      |> Graph.add_edge(Graph.start(), :node1)
      |> Graph.add_edge(:node2, Graph.end_node())
      |> Graph.compile!(checkpointer: checkpointer, interrupt_before: [:node1])

    config = %{"configurable" => %{"thread_id" => "langgraph-command-input-goto"}}

    assert {:interrupted, %{timing: :before, nodes: ["node1"]}} =
             Compiled.invoke(graph, %{foo: "abc"}, config: config)

    assert {:ok, %{foo: "abc|node-1|node-2|node-2"}} =
             Compiled.invoke(graph, %BeamWeaver.Graph.Command{goto: [:node2]}, config: config)
  end

  test "command input resume continues from a static interrupt checkpoint" do
    checkpointer = CheckpointETS.new()

    graph =
      Graph.new()
      |> Graph.add_reducer(:foo, &<>/2)
      |> Graph.add_node(:node1, fn _state -> %{foo: "|node-1"} end)
      |> Graph.add_node(:node2, fn _state -> %{foo: "|node-2"} end)
      |> Graph.add_edge(:node1, :node2)
      |> Graph.add_edge(Graph.start(), :node1)
      |> Graph.add_edge(:node2, Graph.end_node())
      |> Graph.compile!(checkpointer: checkpointer, interrupt_before: [:node1])

    config = %{"configurable" => %{"thread_id" => "langgraph-command-input-static-resume"}}

    assert {:interrupted, %{timing: :before, nodes: ["node1"]}} =
             Compiled.invoke(graph, %{foo: "abc"}, config: config)

    assert {:ok, %{foo: "abc|node-1|node-2"}} =
             Compiled.invoke(graph, %BeamWeaver.Graph.Command{resume: "node1"}, config: config)
  end

  test "command input resume continues interrupted checkpoint" do
    checkpointer = CheckpointETS.new()

    graph =
      Graph.new()
      |> Graph.add_node(:ask, fn _state ->
        answer = Graph.interrupt("question?")
        %{answer: answer}
      end)
      |> Graph.add_edge(Graph.start(), :ask)
      |> Graph.add_edge(:ask, Graph.end_node())
      |> Graph.compile!(checkpointer: checkpointer)

    config = %{"configurable" => %{"thread_id" => "langgraph-command-input-resume"}}

    assert {:interrupted, %{value: "question?"}} = Compiled.invoke(graph, %{}, config: config)

    assert {:ok, %{answer: "answer"}} =
             Compiled.invoke(graph, %BeamWeaver.Graph.Command{resume: "answer"}, config: config)
  end

  test "scheduler runs only nodes subscribed to updated branch channels" do
    parent = self()
    checkpointer = CheckpointETS.new()

    graph =
      Graph.new()
      |> Graph.add_node(:start, fn _state -> %{route: :left} end)
      |> Graph.add_node(:left, fn _state ->
        send(parent, :left_ran)
        %{answer: :left}
      end)
      |> Graph.add_node(:right, fn _state ->
        send(parent, :right_ran)
        %{answer: :right}
      end)
      |> Graph.add_edge(Graph.start(), :start)
      |> Graph.add_edge(:start, :left, when: %{route: :left})
      |> Graph.add_edge(:start, :right, when: %{route: :right})
      |> Graph.add_edge(:left, Graph.end_node())
      |> Graph.add_edge(:right, Graph.end_node())
      |> Graph.compile!(checkpointer: checkpointer)

    config = %{"configurable" => %{"thread_id" => "langgraph-branch-channel-subscription"}}

    assert {:ok, %{answer: :left}} = Compiled.invoke(graph, %{}, config: config)
    assert_receive :left_ran
    refute_receive :right_ran, 50

    start_checkpoint =
      graph
      |> Compiled.get_state_history(config)
      |> Enum.find(&(&1.metadata["source"] == "loop" and &1.metadata["step"] == 0))

    assert "__branch__:start:left" in start_checkpoint.updated_channels
    refute "__branch__:__start__:right" in start_checkpoint.updated_channels
    assert start_checkpoint.next == ["left"]
  end

  test "scheduler runs nodes subscribed to changed state channels without static edges" do
    parent = self()

    graph =
      Graph.new()
      |> Graph.add_node(:source, fn _state -> %{signal: "ready"} end)
      |> Graph.add_node(
        :listener,
        fn state ->
          send(parent, :listener_ran)
          %{observed: state.signal}
        end,
        triggers: [:signal]
      )
      |> Graph.add_node(
        :unrelated,
        fn _state ->
          send(parent, :unrelated_ran)
          %{observed: "wrong"}
        end,
        triggers: [:other]
      )
      |> Graph.add_edge(Graph.start(), :source)
      |> Graph.add_edge(:listener, Graph.end_node())
      |> Graph.compile!()

    assert {:ok, %{signal: "ready", observed: "ready"}} = Compiled.invoke(graph, %{})
    assert_receive :listener_ran
    refute_receive :unrelated_ran, 50
  end

  test "schema-derived channel subscriptions drive scheduling and channel merge semantics" do
    parent = self()

    graph =
      Graph.new(
        state_schema: %{
          topic: [channel: Topic, subscribers: [:listener]],
          other_topic: [channel: Topic, subscribers: [:unrelated]]
        }
      )
      |> Graph.add_node(:source, fn _state -> %{topic: "ready"} end)
      |> Graph.add_node(:listener, fn state ->
        send(parent, {:listener_ran, state.topic})
        %{observed: state.topic}
      end)
      |> Graph.add_node(:unrelated, fn state ->
        send(parent, {:unrelated_ran, state[:other_topic]})
        %{observed: :wrong}
      end)
      |> Graph.add_edge(Graph.start(), :source)
      |> Graph.add_edge(:listener, Graph.end_node())
      |> Graph.compile!()

    assert {:ok, %{topic: ["ready"], observed: ["ready"]}} = Compiled.invoke(graph, %{})
    assert_receive {:listener_ran, ["ready"]}
    refute_receive {:unrelated_ran, _value}, 50
  end

  test "delta channels checkpoint as deltas and restore values from checkpoint history" do
    checkpointer = CheckpointETS.new()
    reducer = fn existing, writes -> existing ++ writes end

    graph =
      Graph.new(
        state_schema: %{
          items: [channel: {DeltaChannel, reducer}, subscribers: [:listener]]
        }
      )
      |> Graph.add_node(:source, fn _state -> %{items: "a"} end)
      |> Graph.add_node(:listener, fn state -> %{seen: state.items} end)
      |> Graph.add_edge(Graph.start(), :source)
      |> Graph.add_edge(:listener, Graph.end_node())
      |> Graph.compile!(checkpointer: checkpointer)

    config = %{"configurable" => %{"thread_id" => "langgraph-delta-channel-history"}}

    assert {:ok, %{items: ["a"], seen: ["a"]}} = Compiled.invoke(graph, %{}, config: config)
    assert {:ok, snapshot} = Compiled.get_state(graph, config)
    assert snapshot.values.items == ["a"]

    tuple = Checkpoint.get_tuple(checkpointer, snapshot.config)
    refute Map.has_key?(tuple.checkpoint["channel_values"], :items)
    refute Map.has_key?(tuple.checkpoint["channel_values"], "items")

    assert Enum.any?(Checkpoint.list(checkpointer, config), fn tuple ->
             get_in(tuple.checkpoint, ["channel_deltas", "items"]) == ["a"]
           end)

    [latest | _history] = Compiled.get_state_history(graph, config)
    assert latest.values.items == ["a"]
  end

  test "scratchpad call and subgraph counters are task-local monotonic counters" do
    graph =
      Graph.new()
      |> Graph.add_node(:first, fn _state ->
        %{
          first_calls: [Scratchpad.next_call(), Scratchpad.next_call()],
          first_subgraphs: [Scratchpad.next_subgraph(), Scratchpad.next_subgraph()]
        }
      end)
      |> Graph.add_node(:second, fn _state ->
        %{
          second_calls: [Scratchpad.next_call(), Scratchpad.next_call()],
          second_subgraphs: [Scratchpad.next_subgraph(), Scratchpad.next_subgraph()]
        }
      end)
      |> Graph.add_edge(Graph.start(), :first)
      |> Graph.add_edge(Graph.start(), :second)
      |> Graph.add_edge(:first, Graph.end_node())
      |> Graph.add_edge(:second, Graph.end_node())
      |> Graph.compile!()

    assert {:ok,
            %{
              first_calls: [0, 1],
              first_subgraphs: [0, 1],
              second_calls: [0, 1],
              second_subgraphs: [0, 1]
            }} = Compiled.invoke(graph, %{})
  end

  test "proceed policy persists every sibling failure and successful writes" do
    checkpointer = CheckpointETS.new()

    graph =
      Graph.new()
      |> Graph.add_node(:ok, fn _state -> %{kept: "yes"} end)
      |> Graph.add_node(:fail_a, fn _state -> {:error, Error.new(:boom_a, "first failure")} end)
      |> Graph.add_node(:fail_b, fn _state -> {:error, Error.new(:boom_b, "second failure")} end)
      |> Graph.add_edge(Graph.start(), :ok)
      |> Graph.add_edge(Graph.start(), :fail_a)
      |> Graph.add_edge(Graph.start(), :fail_b)
      |> Graph.add_edge(:ok, Graph.end_node())
      |> Graph.add_edge(:fail_a, Graph.end_node())
      |> Graph.add_edge(:fail_b, Graph.end_node())
      |> Graph.compile!(checkpointer: checkpointer, failure_policy: :proceed)

    config = %{"configurable" => %{"thread_id" => "langgraph-proceed-all-failures"}}

    assert {:error, %Error{type: type}} = Compiled.invoke(graph, %{}, config: config)
    assert type in [:boom_a, :boom_b]

    assert {:ok, snapshot} = Compiled.get_state(graph, config)
    assert [{_task_id, "kept", "yes"}] = data_writes(snapshot.pending_writes)

    assert snapshot.pending_writes
           |> error_writes()
           |> Enum.map(fn {_task_id, "__error__", error} -> error.type end)
           |> Enum.sort() == [:boom_a, :boom_b]
  end

  test "forking from explicit checkpoint does not apply pending writes from original execution" do
    checkpointer = CheckpointETS.new()

    graph =
      Graph.new()
      |> Graph.add_reducer(:value, &+/2)
      |> Graph.add_node(:node_a, fn _state -> %{value: 10} end)
      |> Graph.add_node(:node_b, fn _state -> %{value: 100} end)
      |> Graph.add_edge(:node_a, :node_b)
      |> Graph.add_edge(Graph.start(), :node_a)
      |> Graph.add_edge(:node_b, Graph.end_node())
      |> Graph.compile!(checkpointer: checkpointer)

    config = %{"configurable" => %{"thread_id" => "langgraph-fork-no-pending"}}

    assert {:ok, %{value: 111}} = Compiled.invoke(graph, %{value: 1}, config: config)

    checkpoint_before_a =
      graph
      |> Compiled.get_state_history(config)
      |> Enum.find(&(&1.next == ["node_a"]))

    assert {:ok, fork_config} =
             Compiled.update_state(graph, checkpoint_before_a.config, %{value: 20}, as_node: :node_a)

    assert {:ok, %{value: 121}} = Compiled.invoke(graph, %{}, config: fork_config)
  end

  test "cached node hit skips execution and replays writes" do
    parent = self()
    cache = BeamWeaver.Cache.ETS.new()

    graph =
      Graph.new()
      |> Graph.add_node(
        :setup,
        fn state ->
          send(parent, :setup_called)
          %{n: state.x}
        end,
        cache: true
      )
      |> Graph.add_edge(Graph.start(), :setup)
      |> Graph.add_edge(:setup, Graph.end_node())
      |> Graph.compile!(cache: cache)

    assert {:ok, %{n: 1, x: 1}} = Compiled.invoke(graph, %{x: 1})
    assert_receive :setup_called

    assert {:ok, %{n: 1, x: 1}} = Compiled.invoke(graph, %{x: 1})
    refute_receive :setup_called, 50

    assert :ok = Compiled.clear_cache(graph)

    assert {:ok, %{n: 1, x: 1}} = Compiled.invoke(graph, %{x: 1})
    assert_receive :setup_called

    assert :ok = Compiled.async_clear_cache(graph) |> Async.await()
  end

  test "cached node requires an explicit cache adapter" do
    graph =
      Graph.new()
      |> Graph.add_node(:setup, fn state -> state end, cache: true)
      |> Graph.add_edge(Graph.start(), :setup)
      |> Graph.add_edge(:setup, Graph.end_node())

    assert {:error, %BeamWeaver.Core.Error{type: :explicit_cache_required}} =
             Graph.compile(graph)
  end

  test "parent command from subgraph updates parent state and routes to parent node" do
    child =
      Graph.new()
      |> Graph.add_reducer(:dialog_state, fn existing, update -> existing ++ List.wrap(update) end)
      |> Graph.add_node(:child_a, fn _state -> %{dialog_state: ["child_a"]} end)
      |> Graph.add_node(:child_b, fn _state ->
        %BeamWeaver.Graph.Command{
          graph: BeamWeaver.Graph.Command.parent(),
          goto: :parent_b,
          update: %{dialog_state: ["child_b"]}
        }
      end)
      |> Graph.add_edge(:child_a, :child_b)
      |> Graph.add_edge(Graph.start(), :child_a)
      |> Graph.compile!()

    parent =
      Graph.new()
      |> Graph.add_reducer(:dialog_state, fn existing, update -> existing ++ List.wrap(update) end)
      |> Graph.add_node(:subgraph, child, input: fn _state -> %{value: []} end)
      |> Graph.add_node(:parent_b, fn _state -> %{dialog_state: ["parent_b"]} end)
      |> Graph.add_edge(Graph.start(), :subgraph)
      |> Graph.add_edge(:parent_b, Graph.end_node())
      |> Graph.compile!()

    assert {:ok, %{dialog_state: ["init", "child_b", "parent_b"]}} =
             Compiled.invoke(parent, %{dialog_state: ["init"]})
  end

  test "parent command from deeply nested subgraph targets the immediate parent graph" do
    sub_sub_graph =
      Graph.new(name: "sub_sub_graph")
      |> Graph.add_reducer(:dialog_state, fn existing, update -> existing ++ List.wrap(update) end)
      |> Graph.add_node(:sub_sub_child, fn _state ->
        %BeamWeaver.Graph.Command{
          graph: BeamWeaver.Graph.Command.parent(),
          goto: :sub_child_3,
          update: %{dialog_state: ["sub_sub_child"]}
        }
      end)
      |> Graph.add_edge(Graph.start(), :sub_sub_child)
      |> Graph.compile!()

    sub_graph =
      Graph.new(name: "sub_graph")
      |> Graph.add_reducer(:dialog_state, fn existing, update -> existing ++ List.wrap(update) end)
      |> Graph.add_node(:sub_child_1, fn _state -> %{dialog_state: ["sub_child_1"]} end)
      |> Graph.add_node(:sub_child_2, sub_sub_graph)
      |> Graph.add_node(:sub_child_3, fn _state -> %{dialog_state: ["sub_child_3"]} end)
      |> Graph.add_edge(:sub_child_1, :sub_child_2)
      |> Graph.add_edge(Graph.start(), :sub_child_1)
      |> Graph.add_edge(:sub_child_3, Graph.end_node())
      |> Graph.compile!()

    graph =
      Graph.new(name: "main_graph")
      |> Graph.add_reducer(:dialog_state, fn existing, update -> existing ++ List.wrap(update) end)
      |> Graph.add_node(:child_1, fn _state -> %{dialog_state: ["child_1"]} end)
      |> Graph.add_node(:child_2, sub_graph)
      |> Graph.add_edge(:child_1, :child_2)
      |> Graph.add_edge(Graph.start(), :child_1)
      |> Graph.add_edge(:child_2, Graph.end_node())
      |> Graph.compile!()

    assert {:ok,
            %{
              dialog_state: [
                "init",
                "child_1",
                "init",
                "child_1",
                "sub_child_1",
                "sub_sub_child",
                "sub_child_3"
              ]
            }} = Compiled.invoke(graph, %{dialog_state: ["init"]})
  end

  test "named graph command bubbles until the matching subgraph handles it" do
    sub_sub_graph =
      Graph.new(name: "sub_sub_graph")
      |> Graph.add_reducer(:dialog_state, fn existing, update -> existing ++ List.wrap(update) end)
      |> Graph.add_node(:sub_sub_child, fn _state ->
        %BeamWeaver.Graph.Command{
          graph: "sub_graph",
          goto: :sub_child_3,
          update: %{dialog_state: ["sub_sub_child"]}
        }
      end)
      |> Graph.add_edge(Graph.start(), :sub_sub_child)
      |> Graph.compile!()

    sub_graph =
      Graph.new(name: "sub_graph")
      |> Graph.add_reducer(:dialog_state, fn existing, update -> existing ++ List.wrap(update) end)
      |> Graph.add_node(:sub_child_1, fn _state -> %{dialog_state: ["sub_child_1"]} end)
      |> Graph.add_node(:sub_child_2, sub_sub_graph)
      |> Graph.add_node(:sub_child_3, fn _state -> %{dialog_state: ["sub_child_3"]} end)
      |> Graph.add_edge(:sub_child_1, :sub_child_2)
      |> Graph.add_edge(Graph.start(), :sub_child_1)
      |> Graph.add_edge(:sub_child_3, Graph.end_node())
      |> Graph.compile!()

    graph =
      Graph.new(name: "main_graph")
      |> Graph.add_reducer(:dialog_state, fn existing, update -> existing ++ List.wrap(update) end)
      |> Graph.add_node(:child_1, fn _state -> %{dialog_state: ["child_1"]} end)
      |> Graph.add_node(:child_2, sub_graph)
      |> Graph.add_edge(:child_1, :child_2)
      |> Graph.add_edge(Graph.start(), :child_1)
      |> Graph.add_edge(:child_2, Graph.end_node())
      |> Graph.compile!()

    assert {:ok,
            %{
              dialog_state: [
                "init",
                "child_1",
                "init",
                "child_1",
                "sub_child_1",
                "sub_sub_child",
                "sub_child_3"
              ]
            }} = Compiled.invoke(graph, %{dialog_state: ["init"]})
  end

  test "subgraph pending writes replay without rerunning completed child task" do
    parent_pid = self()
    checkpointer = CheckpointETS.new()

    child =
      Graph.new()
      |> Graph.add_reducer(:child_value, &+/2)
      |> Graph.add_node(:one, fn _state ->
        send(parent_pid, :child_one_called)
        %{child_value: 2}
      end)
      |> Graph.add_node(:two, fn state ->
        send(parent_pid, :child_two_called)

        if state[:retry_ok],
          do: %{child_value: 3},
          else: {:error, Error.new(:connection_error, "child failed")}
      end)
      |> Graph.add_edge(Graph.start(), :one)
      |> Graph.add_edge(Graph.start(), :two)
      |> Graph.add_edge(:one, Graph.end_node())
      |> Graph.add_edge(:two, Graph.end_node())
      |> Graph.compile!()

    parent =
      Graph.new()
      |> Graph.add_reducer(:child_value, &+/2)
      |> Graph.add_node(:child, child)
      |> Graph.add_edge(Graph.start(), :child)
      |> Graph.add_edge(:child, Graph.end_node())
      |> Graph.compile!(checkpointer: checkpointer)

    config = %{"configurable" => %{"thread_id" => "langgraph-subgraph-pending-replay"}}

    assert {:error, %Error{type: :connection_error}} =
             Compiled.invoke(parent, %{child_value: 0}, config: config)

    assert_receive :child_one_called
    assert_receive :child_two_called

    assert {:ok, parent_snapshot} = Compiled.get_state(parent, config)

    assert [{parent_task_id, "__error__", %Error{type: :connection_error}}] =
             error_writes(parent_snapshot.pending_writes)

    child_config = %{
      "configurable" => %{
        "thread_id" => "langgraph-subgraph-pending-replay",
        "checkpoint_ns" => "child:#{parent_task_id}"
      }
    }

    assert {:ok, child_snapshot} =
             Compiled.get_state(%{child | checkpointer: checkpointer}, child_config)

    assert child_snapshot.values.child_value == 2
    assert child_snapshot.next == ["two"]

    assert {:ok, %{child_value: 5}} = Compiled.invoke(parent, %{retry_ok: true}, config: config)

    assert_receive :child_two_called
    refute_receive :child_one_called, 50
  end

  test "parent compiled graph delegates state APIs to child checkpoint namespace" do
    checkpointer = CheckpointETS.new()

    child =
      Graph.new()
      |> Graph.add_reducer(:child_value, &+/2)
      |> Graph.add_node(:one, fn _state -> %{child_value: 1} end)
      |> Graph.add_node(:two, fn _state -> %{child_value: 2} end)
      |> Graph.add_edge(:one, :two)
      |> Graph.add_edge(Graph.start(), :one)
      |> Graph.add_edge(:two, Graph.end_node())
      |> Graph.compile!()

    parent =
      Graph.new()
      |> Graph.add_reducer(:child_value, &+/2)
      |> Graph.add_node(:child, child)
      |> Graph.add_edge(Graph.start(), :child)
      |> Graph.add_edge(:child, Graph.end_node())
      |> Graph.compile!(checkpointer: checkpointer)

    config = %{"configurable" => %{"thread_id" => "langgraph-parent-child-state-api"}}

    assert {:ok, %{child_value: 3}} = Compiled.invoke(parent, %{child_value: 0}, config: config)
    assert {:ok, parent_snapshot} = Compiled.get_state(parent, config)

    child_task =
      Enum.find(parent_snapshot.tasks, &(&1.node == "child" and &1.kind == :start))

    child_config = %{
      "configurable" => %{
        "thread_id" => "langgraph-parent-child-state-api",
        "checkpoint_ns" => "child:#{child_task.id}"
      }
    }

    assert {:ok, child_snapshot} = Compiled.get_state(parent, child_config)
    assert child_snapshot.values == %{child_value: 3}

    assert {:ok, fork_config} =
             Compiled.update_state(parent, child_snapshot.config, %{child_value: 10}, as_node: :one)

    assert {:ok, fork_snapshot} = Compiled.get_state(parent, fork_config)
    assert fork_snapshot.values == %{child_value: 13}
    assert fork_snapshot.next == ["two"]

    assert {:ok, %{child_value: 15}} =
             Compiled.invoke(%{child | checkpointer: checkpointer}, %{}, config: fork_config)
  end

  test "time travel from final checkpoint is a no-op and sibling forks stay independent" do
    parent = self()
    checkpointer = CheckpointETS.new()

    graph =
      Graph.new()
      |> Graph.add_reducer(:value, fn existing, update ->
        List.wrap(existing) ++ List.wrap(update)
      end)
      |> Graph.add_node(:node_a, fn _state ->
        send(parent, :node_a_called)
        %{value: ["a"]}
      end)
      |> Graph.add_node(:node_b, fn _state ->
        send(parent, :node_b_called)
        %{value: ["b"]}
      end)
      |> Graph.add_edge(Graph.start(), :node_a)
      |> Graph.add_edge(:node_a, :node_b)
      |> Graph.add_edge(:node_b, Graph.end_node())
      |> Graph.compile!(checkpointer: checkpointer)

    config = %{"configurable" => %{"thread_id" => "langgraph-time-travel-final-noop"}}

    assert {:ok, %{value: ["a", "b"]}} = Compiled.invoke(graph, %{value: []}, config: config)
    assert_receive :node_a_called
    assert_receive :node_b_called

    history = Compiled.get_state_history(graph, config)
    before_b = Enum.find(history, &(&1.next == ["node_b"]))
    final_state = Enum.find(history, &(&1.next == []))

    assert {:ok, %{value: ["a", "b"]}} = Compiled.invoke(graph, %{}, config: final_state.config)
    refute_receive :node_a_called, 50
    refute_receive :node_b_called, 50

    assert {:ok, fork_one} =
             Compiled.update_state(graph, before_b.config, %{value: ["x"]}, as_node: :node_a)

    assert {:ok, fork_two} =
             Compiled.update_state(graph, before_b.config, %{value: ["y"]}, as_node: :node_a)

    assert {:ok, %{value: ["a", "x", "b"]}} = Compiled.invoke(graph, %{}, config: fork_one)
    assert {:ok, %{value: ["a", "y", "b"]}} = Compiled.invoke(graph, %{}, config: fork_two)
    assert_receive :node_b_called
    assert_receive :node_b_called
    refute_receive :node_a_called, 50
  end

  test "runtime config exposes checkpoint namespace inside subgraph nodes" do
    parent = self()
    checkpointer = CheckpointETS.new()

    child =
      Graph.new()
      |> Graph.add_node(:inner, fn _state, runtime ->
        send(
          parent,
          {:child_config, runtime.execution.checkpoint_ns, runtime.execution.thread_id}
        )

        %{data: "done"}
      end)
      |> Graph.add_edge(Graph.start(), :inner)
      |> Graph.add_edge(:inner, Graph.end_node())
      |> Graph.compile!()

    parent_graph =
      Graph.new()
      |> Graph.add_node(:outer, child)
      |> Graph.add_edge(Graph.start(), :outer)
      |> Graph.add_edge(:outer, Graph.end_node())
      |> Graph.compile!(checkpointer: checkpointer)

    config = %{"configurable" => %{"thread_id" => "langgraph-subgraph-config"}}

    assert {:ok, %{data: "done"}} =
             Compiled.invoke(parent_graph, %{data: "input"}, config: config)

    assert_receive {:child_config, checkpoint_ns, "langgraph-subgraph-config"}
    assert is_binary(checkpoint_ns)
    assert checkpoint_ns != ""
  end

  test "subgraph replay and fork run child work without rerunning completed parent nodes" do
    parent = self()
    checkpointer = CheckpointETS.new()

    child =
      Graph.new()
      |> Graph.add_reducer(:value, fn existing, update ->
        List.wrap(existing) ++ List.wrap(update)
      end)
      |> Graph.add_node(:step_a, fn _state ->
        send(parent, :sub_step_a)
        %{value: ["sub_a"]}
      end)
      |> Graph.add_node(:step_b, fn _state ->
        send(parent, :sub_step_b)
        %{value: ["sub_b"]}
      end)
      |> Graph.add_edge(:step_a, :step_b)
      |> Graph.add_edge(Graph.start(), :step_a)
      |> Graph.add_edge(:step_b, Graph.end_node())
      |> Graph.compile!(checkpointer: false)

    graph =
      Graph.new()
      |> Graph.add_reducer(:value, fn existing, update ->
        List.wrap(existing) ++ List.wrap(update)
      end)
      |> Graph.add_node(:parent_node, fn _state ->
        send(parent, :parent_node)
        %{value: ["parent"]}
      end)
      |> Graph.add_node(:subgraph, child, input: fn _state -> %{value: []} end)
      |> Graph.add_node(:post_process, fn _state ->
        send(parent, :post_process)
        %{value: ["post"]}
      end)
      |> Graph.add_edge(:parent_node, :subgraph)
      |> Graph.add_edge(:subgraph, :post_process)
      |> Graph.add_edge(Graph.start(), :parent_node)
      |> Graph.add_edge(:post_process, Graph.end_node())
      |> Graph.compile!(checkpointer: checkpointer)

    config = %{"configurable" => %{"thread_id" => "langgraph-subgraph-replay-fork"}}

    assert {:ok, %{value: ["parent", "sub_a", "sub_b", "post"]}} =
             Compiled.invoke(graph, %{value: []}, config: config)

    assert_receive :parent_node
    assert_receive :sub_step_a
    assert_receive :sub_step_b
    assert_receive :post_process

    before_subgraph =
      graph
      |> Compiled.get_state_history(config)
      |> Enum.find(&(&1.next == ["subgraph"]))

    assert {:ok, %{value: ["parent", "sub_a", "sub_b", "post"]}} =
             Compiled.invoke(graph, %{}, config: before_subgraph.config)

    refute_receive :parent_node, 50
    assert_receive :sub_step_a
    assert_receive :sub_step_b
    assert_receive :post_process

    assert {:ok, fork_config} =
             Compiled.update_state(graph, before_subgraph.config, %{value: ["fork"]}, as_node: :parent_node)

    assert {:ok, %{value: ["parent", "fork", "sub_a", "sub_b", "post"]}} =
             Compiled.invoke(graph, %{}, config: fork_config)

    refute_receive :parent_node, 50
    assert_receive :sub_step_a
    assert_receive :sub_step_b
    assert_receive :post_process
  end

  test "subgraph checkpoint scopes support stateful replay and stateless fresh starts" do
    parent = self()
    checkpointer = CheckpointETS.new()

    subgraph = fn opts ->
      Graph.new()
      |> Graph.add_reducer(:value, fn existing, update ->
        List.wrap(existing) ++ List.wrap(update)
      end)
      |> Graph.add_node(:step_a, fn state ->
        send(parent, {:step_a_started, Keyword.fetch!(opts, :label), Map.get(state, :value, [])})
        answer = Graph.interrupt("question_a")
        %{value: ["a:#{answer}"]}
      end)
      |> Graph.add_node(:step_b, fn state ->
        send(parent, {:step_b_started, Keyword.fetch!(opts, :label), Map.get(state, :value, [])})
        answer = Graph.interrupt("question_b")
        %{value: ["b:#{answer}"]}
      end)
      |> Graph.add_edge(:step_a, :step_b)
      |> Graph.add_edge(Graph.start(), :step_a)
      |> Graph.add_edge(:step_b, Graph.end_node())
      |> Graph.compile!(checkpointer: Keyword.fetch!(opts, :checkpointer))
    end

    parent_graph = fn child, thread_id ->
      Graph.new()
      |> Graph.add_reducer(:results, fn existing, update ->
        List.wrap(existing) ++ List.wrap(update)
      end)
      |> Graph.add_node(:parent, fn _state -> %{results: ["p"]} end)
      |> Graph.add_node(:sub_node, child,
        input: fn _state -> %{value: []} end,
        output: fn _child_output -> %{results: ["sub_done"]} end
      )
      |> Graph.add_edge(:parent, :sub_node)
      |> Graph.add_edge(Graph.start(), :parent)
      |> Graph.add_edge(:sub_node, Graph.end_node())
      |> Graph.compile!(checkpointer: checkpointer)
      |> then(&{&1, %{"configurable" => %{"thread_id" => thread_id}}})
    end

    {stateful, stateful_config} =
      subgraph.(label: :stateful, checkpointer: true)
      |> parent_graph.("langgraph-stateful-subgraph-replay")

    assert {:interrupted, first_a} =
             Compiled.invoke(stateful, %{results: []}, config: stateful_config)

    assert first_a.value == "question_a"
    assert_receive {:step_a_started, :stateful, []}
    assert {:interrupted, first_b} = Compiled.resume(stateful, "a1", config: stateful_config)
    assert first_b.value == "question_b"
    assert_receive {:step_b_started, :stateful, ["a:a1"]}

    assert {:ok, %{results: ["p", "sub_done"]}} =
             Compiled.resume(stateful, "b1", config: stateful_config)

    assert {:interrupted, second_a} =
             Compiled.invoke(stateful, %{results: []}, config: stateful_config)

    assert second_a.value == "question_a"
    assert_receive {:step_a_started, :stateful, ["a:a1", "b:b1"]}

    stateless_child =
      Graph.new()
      |> Graph.add_reducer(:value, fn existing, update ->
        List.wrap(existing) ++ List.wrap(update)
      end)
      |> Graph.add_node(:step_a, fn state ->
        send(parent, {:step_a_started, :stateless, Map.get(state, :value, [])})
        answer = Graph.interrupt("question_a")
        %{value: ["a:#{answer}"]}
      end)
      |> Graph.add_edge(Graph.start(), :step_a)
      |> Graph.add_edge(:step_a, Graph.end_node())
      |> Graph.compile!(checkpointer: false)

    {stateless, stateless_config} =
      stateless_child
      |> parent_graph.("langgraph-stateless-subgraph-replay")

    assert {:interrupted, stateless_a} =
             Compiled.invoke(stateless, %{results: []}, config: stateless_config)

    assert stateless_a.value == "question_a"
    assert_receive {:step_a_started, :stateless, []}

    assert {:ok, %{results: ["p", "sub_done"]}} =
             Compiled.resume(stateless, "a1", config: stateless_config)

    assert {:interrupted, stateless_second_a} =
             Compiled.invoke(stateless, %{results: []}, config: stateless_config)

    assert stateless_second_a.value == "question_a"
    assert_receive {:step_a_started, :stateless, []}
  end

  test "nested subgraph checkpoint maps replay innermost interrupt without rerunning prior nodes" do
    parent = self()
    checkpointer = CheckpointETS.new()

    inner =
      Graph.new()
      |> Graph.add_reducer(:value, fn existing, update ->
        List.wrap(existing) ++ List.wrap(update)
      end)
      |> Graph.add_node(:step_a, fn _state ->
        send(parent, :step_a)
        %{value: ["step_a_done"]}
      end)
      |> Graph.add_node(:ask_1, fn _state ->
        send(parent, :ask_1)
        answer = Graph.interrupt("Question 1?")
        %{value: ["ask_1:#{answer}"]}
      end)
      |> Graph.add_node(:ask_2, fn _state ->
        send(parent, :ask_2)
        answer = Graph.interrupt("Question 2?")
        %{value: ["ask_2:#{answer}"]}
      end)
      |> Graph.add_edge(:step_a, :ask_1)
      |> Graph.add_edge(:ask_1, :ask_2)
      |> Graph.add_edge(Graph.start(), :step_a)
      |> Graph.add_edge(:ask_2, Graph.end_node())
      |> Graph.compile!(checkpointer: true)

    middle =
      Graph.new()
      |> Graph.add_node(:inner, inner)
      |> Graph.add_edge(Graph.start(), :inner)
      |> Graph.add_edge(:inner, Graph.end_node())
      |> Graph.compile!(checkpointer: true)

    graph =
      Graph.new()
      |> Graph.add_node(:outer, middle)
      |> Graph.add_edge(Graph.start(), :outer)
      |> Graph.add_edge(:outer, Graph.end_node())
      |> Graph.compile!(checkpointer: checkpointer)

    config = %{"configurable" => %{"thread_id" => "langgraph-nested-time-travel"}}

    assert {:interrupted, first} = Compiled.invoke(graph, %{value: []}, config: config)
    assert first.value == "Question 1?"

    inner_first_config =
      graph
      |> Compiled.get_state_history(config)
      |> Enum.find(fn snapshot ->
        get_in(snapshot.config, ["configurable", "checkpoint_ns"]) == "outer/inner" and
          snapshot.next == ["ask_1"]
      end)
      |> Map.fetch!(:config)

    assert get_in(inner_first_config, ["configurable", "checkpoint_map", ""]) != nil
    assert get_in(inner_first_config, ["configurable", "checkpoint_map", "outer"]) != nil
    assert get_in(inner_first_config, ["configurable", "checkpoint_map", "outer/inner"]) != nil

    assert {:interrupted, second} = Compiled.resume(graph, "old-1", config: config)
    assert second.value == "Question 2?"

    inner_second_config =
      graph
      |> Compiled.get_state_history(config)
      |> Enum.find(fn snapshot ->
        get_in(snapshot.config, ["configurable", "checkpoint_ns"]) == "outer/inner" and
          snapshot.next == ["ask_2"]
      end)
      |> Map.fetch!(:config)

    assert {:ok, %{value: ["step_a_done", "ask_1:old-1", "ask_2:old-2"]}} =
             Compiled.resume(graph, "old-2", config: config)

    flush_messages()

    assert {:interrupted, replayed} = Compiled.invoke(graph, %{}, config: inner_first_config)
    assert replayed.value == "Question 1?"
    assert get_in(replayed.config, ["configurable", "checkpoint_target_ns"]) == "outer/inner"

    refute_receive :step_a, 50
    assert_receive :ask_1
    refute_receive :ask_2, 50

    assert {:ok, fork_config} =
             Compiled.update_state(graph, inner_first_config, %{value: ["forked"]})

    flush_messages()

    assert {:interrupted, forked} = Compiled.invoke(graph, %{}, config: fork_config)
    assert forked.value == "Question 1?"
    refute_receive :step_a, 50
    assert_receive :ask_1
    refute_receive :ask_2, 50

    assert {:interrupted, forked_after_first_resume} =
             Compiled.resume(graph, "fork-1", config: forked.config)

    assert forked_after_first_resume.value == "Question 2?"
    refute_receive :step_a, 50
    assert_receive :ask_1
    assert_receive :ask_2

    assert {:ok, %{value: ["step_a_done", "forked", "ask_1:fork-1", "ask_2:fork-2"]}} =
             Compiled.resume(graph, "fork-2", config: forked_after_first_resume.config)

    refute_receive :step_a, 50
    refute_receive :ask_1, 50
    assert_receive :ask_2

    flush_messages()

    assert {:interrupted, replayed_second} =
             Compiled.invoke(graph, %{}, config: inner_second_config)

    assert replayed_second.value == "Question 2?"
    refute_receive :step_a, 50
    refute_receive :ask_1, 50
    assert_receive :ask_2

    assert {:ok, second_fork_config} =
             Compiled.update_state(graph, inner_second_config, %{value: ["forked-second"]})

    flush_messages()

    assert {:interrupted, forked_second} =
             Compiled.invoke(graph, %{}, config: second_fork_config)

    assert forked_second.value == "Question 2?"
    refute_receive :step_a, 50
    refute_receive :ask_1, 50
    assert_receive :ask_2
  end

  defp data_writes(writes), do: Enum.reject(writes, &control_write?/1)
  defp data_write_paths(paths), do: Enum.reject(paths, &control_write?/1)
  defp error_writes(writes), do: Enum.filter(writes, &match?({_task_id, "__error__", _error}, &1))

  defp flush_messages do
    receive do
      _message -> flush_messages()
    after
      0 -> :ok
    end
  end

  defp control_write?({_task_id, "__error__", _value}), do: true
  defp control_write?({_task_id, "__interrupt__", _value}), do: true
  defp control_write?(_write), do: false
end
