defmodule BeamWeaver.Graph.ContinueThreadTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Checkpoint.ETS, as: CheckpointETS
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Graph
  alias BeamWeaver.Graph.Command
  alias BeamWeaver.Graph.Compiled
  alias BeamWeaver.Graph.Send
  alias BeamWeaver.Stream.Envelope
  alias BeamWeaver.Stream.Events

  describe "a run stopped by a crash" do
    test "invoke with no new input continues it without rerunning finished nodes" do
      saver = CheckpointETS.new()
      graph = refund_graph(saver)
      config = thread("crash-invoke")

      crash_in_notify(fn context ->
        Compiled.invoke(graph, %{order_id: "A-1", log: []}, config: config, context: context)
      end)

      assert {:ok, %{next: ["notify"], values: %{log: ["refund A-1"]}}} = Compiled.get_state(graph, config)
      assert {:ok, %{log: ["refund A-1", "notified A-1"]}} = Compiled.invoke(graph, %{}, config: config)
    end

    test "resume continues it as well" do
      saver = CheckpointETS.new()
      graph = refund_graph(saver)
      config = thread("crash-resume")

      crash_in_notify(fn context ->
        Compiled.invoke(graph, %{order_id: "A-1", log: []}, config: config, context: context)
      end)

      assert {:ok, %{log: ["refund A-1", "notified A-1"]}} = Compiled.resume(graph, nil, config: config)
    end

    test "the snapshot config still continues it" do
      saver = CheckpointETS.new()
      graph = refund_graph(saver)
      config = thread("crash-snapshot-config")

      crash_in_notify(fn context ->
        Compiled.invoke(graph, %{order_id: "A-1", log: []}, config: config, context: context)
      end)

      {:ok, snapshot} = Compiled.get_state(graph, config)

      assert {:ok, %{log: ["refund A-1", "notified A-1"]}} =
               Compiled.invoke(graph, %{}, config: snapshot.config)
    end

    test "invoke with no new input on a finished thread starts a new run" do
      saver = CheckpointETS.new()
      graph = refund_graph(saver)
      config = thread("finished-thread")

      assert {:ok, _state} = Compiled.invoke(graph, %{order_id: "A-1", log: []}, config: config)

      assert {:ok, %{log: ["refund A-1", "notified A-1", "refund A-1", "notified A-1"]}} =
               Compiled.invoke(graph, %{}, config: config)
    end
  end

  describe "static breakpoints" do
    test "resume continues past interrupt_before and interrupt_after" do
      for {breakpoint, thread_id} <- [
            {[interrupt_before: [:notify]], "before"},
            {[interrupt_after: [:issue_refund]], "after"}
          ] do
        graph = refund_graph(CheckpointETS.new(), breakpoint)
        config = thread(thread_id)

        assert {:interrupted, _interrupt} =
                 Compiled.invoke(graph, %{order_id: "A-1", log: []}, config: config)

        assert {:ok, %{log: ["refund A-1", "notified A-1"]}} = Compiled.resume(graph, nil, config: config)

        assert {:ok, %{log: ["refund A-1", "notified A-1"]}} = Compiled.resume(graph, nil, config: config),
               "resuming a finished thread returns its state"
      end
    end

    test "invoke with no new input continues past a breakpoint" do
      graph = refund_graph(CheckpointETS.new(), interrupt_before: [:notify])
      config = thread("breakpoint-invoke")

      assert {:interrupted, %{timing: :before, nodes: ["notify"]}} =
               Compiled.invoke(graph, %{order_id: "A-1", log: []}, config: config)

      assert {:ok, %{log: ["refund A-1", "notified A-1"]}} = Compiled.invoke(graph, %{}, config: config)
    end

    test "a breakpoint pauses again when the run comes back to its node" do
      graph =
        Graph.new()
        |> Graph.add_node(:count, fn state -> %{count: state.count + 1} end)
        |> Graph.add_edge(Graph.start(), :count)
        |> Graph.add_edge(:count, :count, when: %{count: 0..1})
        |> Graph.add_edge(:count, Graph.end_node(), when: %{count: 2})
        |> Graph.compile!(checkpointer: CheckpointETS.new(), interrupt_before: [:count])

      config = thread("breakpoint-loop")

      assert {:interrupted, %{state: %{count: 0}}} = Compiled.invoke(graph, %{count: 0}, config: config)
      assert {:interrupted, %{state: %{count: 1}}} = Compiled.resume(graph, nil, config: config)
      assert {:ok, %{count: 2}} = Compiled.resume(graph, nil, config: config)
    end

    test "a value that passes a breakpoint doesn't answer a later interrupt" do
      graph =
        Graph.new()
        |> Graph.add_node(:draft, fn _state -> %{reply: "Refund issued."} end)
        |> Graph.add_node(:review, fn state -> %{reviewed: state.reply} end)
        |> Graph.add_node(:send, fn _state -> %{sent: Graph.interrupt("Send it?")} end)
        |> Graph.add_edge(Graph.start(), :draft)
        |> Graph.add_edge(:draft, :review)
        |> Graph.add_edge(:review, :send)
        |> Graph.add_edge(:send, Graph.end_node())
        |> Graph.compile!(checkpointer: CheckpointETS.new(), interrupt_before: [:review])

      config = thread("breakpoint-resume-value")

      assert {:interrupted, %{nodes: ["review"]}} = Compiled.invoke(graph, %{}, config: config)
      assert {:interrupted, %{value: "Send it?"}} = Compiled.resume(graph, "go", config: config)
      assert {:ok, %{sent: "yes"}} = Compiled.resume(graph, "yes", config: config)
    end

    test "stream_events with no new input streams the rest of the run" do
      graph = refund_graph(CheckpointETS.new(), interrupt_before: [:notify])
      config = thread("breakpoint-stream")

      assert {:interrupted, _interrupt} =
               Compiled.invoke(graph, %{order_id: "A-1", log: []}, config: config)

      assert {:ok, events} = Compiled.stream_events(graph, %{}, config: config)

      updated_nodes =
        for %Envelope{event: %Events.GraphUpdate{update: update}} <- events,
            node <- Map.keys(update),
            do: node

      assert updated_nodes == ["notify"]
      assert {:ok, %{next: [], values: %{log: ["refund A-1", "notified A-1"]}}} = Compiled.get_state(graph, config)
    end

    test "resume continues past a breakpoint inside a subgraph" do
      child =
        Graph.new()
        |> Graph.add_node(:check, fn _state -> %{checked: true} end)
        |> Graph.add_node(:refund, fn _state -> %{refunded: true} end)
        |> Graph.add_edge(Graph.start(), :check)
        |> Graph.add_edge(:check, :refund)
        |> Graph.add_edge(:refund, Graph.end_node())
        |> Graph.compile!(interrupt_before: [:refund])

      graph =
        Graph.new()
        |> Graph.add_node(:billing, child)
        |> Graph.add_edge(Graph.start(), :billing)
        |> Graph.add_edge(:billing, Graph.end_node())
        |> Graph.compile!(checkpointer: CheckpointETS.new())

      config = thread("subgraph-breakpoint")

      assert {:interrupted, %{timing: :before, nodes: ["refund"]}} = Compiled.invoke(graph, %{}, config: config)
      assert {:ok, %{checked: true, refunded: true}} = Compiled.resume(graph, nil, config: config)
    end

    test "a command continues a thread stopped at a breakpoint" do
      graph = refund_graph(CheckpointETS.new(), interrupt_before: [:notify])
      config = thread("breakpoint-command")

      assert {:interrupted, _interrupt} =
               Compiled.invoke(graph, %{order_id: "A-1", log: []}, config: config)

      assert {:ok, %{log: ["refund A-1", "notified A-1"]}} =
               Compiled.invoke(graph, %Command{resume: :go}, config: config)
    end

    test "an update as one branch's node keeps the other branch's next node" do
      graph =
        Graph.new()
        |> Graph.add_reducer(:log, &(&1 ++ &2))
        |> Graph.add_node(:a, fn _state -> %{log: ["a"]} end)
        |> Graph.add_node(:b, fn _state -> %{log: ["b"]} end)
        |> Graph.add_node(:after_a, fn _state -> %{log: ["after a"]} end)
        |> Graph.add_node(:after_b, fn _state -> %{log: ["after b"]} end)
        |> Graph.add_edge(Graph.start(), :a)
        |> Graph.add_edge(Graph.start(), :b)
        |> Graph.add_edge(:a, :after_a)
        |> Graph.add_edge(:b, :after_b)
        |> Graph.compile!(checkpointer: CheckpointETS.new(), interrupt_before: [:after_a, :after_b])

      config = thread("breakpoint-update-branch")

      assert {:interrupted, %{nodes: ["after_a", "after_b"]}} = Compiled.invoke(graph, %{log: []}, config: config)
      assert {:ok, _config} = Compiled.update_state(graph, config, %{log: ["a, corrected"]}, as_node: :a)
      assert {:ok, %{next: ["after_a", "after_b"]}} = Compiled.get_state(graph, config)

      assert {:ok, %{log: ["a", "b", "a, corrected", "after a", "after b"]}} =
               Compiled.invoke(graph, %{}, config: config)
    end

    test "an update keeps the node that a command's goto scheduled" do
      graph =
        Graph.new()
        |> Graph.add_node(:classify, fn _state -> %Command{update: %{category: :billing}, goto: :billing} end,
          destinations: [:billing]
        )
        |> Graph.add_node(:billing, fn state -> %{reply: "Routed to #{state.category}."} end)
        |> Graph.add_edge(Graph.start(), :classify)
        |> Graph.add_edge(:billing, Graph.end_node())
        |> Graph.compile!(checkpointer: CheckpointETS.new(), interrupt_before: [:billing])

      config = thread("breakpoint-update-goto")

      assert {:interrupted, %{nodes: ["billing"]}} = Compiled.invoke(graph, %{}, config: config)
      assert {:ok, _config} = Compiled.update_state(graph, config, %{category: :refunds})
      assert {:ok, %{next: ["billing"]}} = Compiled.get_state(graph, config)
      assert {:ok, %{reply: "Routed to refunds."}} = Compiled.invoke(graph, %{}, config: config)
    end
  end

  describe "update_state on a paused thread" do
    test "the next resume continues with the updated state" do
      graph = approval_graph(CheckpointETS.new())
      config = thread("paused-update")

      assert {:interrupted, interrupt} = Compiled.invoke(graph, %{order_id: "A-1"}, config: config)
      assert {:ok, _config} = Compiled.update_state(graph, config, %{reply: "Refund of A-1 is on its way."})

      assert {:ok, snapshot} = Compiled.get_state(graph, config)
      assert snapshot.next == ["review"]
      assert [%{id: id}] = snapshot.interrupts
      assert id == interrupt.id

      assert {:ok, %{approved: "yes", sent: "Refund of A-1 is on its way."}} =
               Compiled.resume(graph, "yes", config: config)
    end

    test "an answer keyed by the interrupt id from before the update still applies" do
      graph = approval_graph(CheckpointETS.new())
      config = thread("paused-update-by-id")

      assert {:interrupted, interrupt} = Compiled.invoke(graph, %{order_id: "A-1"}, config: config)
      assert {:ok, _config} = Compiled.update_state(graph, config, %{reply: "Edited."})

      assert {:ok, %{approved: "yes", sent: "Edited."}} =
               Compiled.resume(graph, %{interrupt.id => "yes"}, config: config)
    end

    test "the writes of nodes that finished in the paused step apply once" do
      graph =
        Graph.new()
        |> Graph.add_reducer(:log, &(&1 ++ &2))
        |> Graph.add_node(:ask, fn _state -> %{log: ["ask:" <> Graph.interrupt("Go on?")]} end)
        |> Graph.add_node(:lookup, fn _state -> %{log: ["lookup"]} end)
        |> Graph.add_edge(Graph.start(), :ask)
        |> Graph.add_edge(Graph.start(), :lookup)
        |> Graph.add_edge(:ask, Graph.end_node())
        |> Graph.add_edge(:lookup, Graph.end_node())
        |> Graph.compile!(checkpointer: CheckpointETS.new())

      config = thread("paused-update-sibling")

      assert {:interrupted, _interrupt} = Compiled.invoke(graph, %{log: []}, config: config)
      assert {:ok, _config} = Compiled.update_state(graph, config, %{log: ["note"]})
      assert {:ok, %{values: %{log: ["lookup", "note"]}, next: ["ask"]}} = Compiled.get_state(graph, config)

      assert {:ok, %{log: ["lookup", "note", "ask:yes"]}} = Compiled.resume(graph, "yes", config: config)
    end

    test "an update as the paused node is its answer: the pause goes and the next node runs" do
      graph = approval_graph(CheckpointETS.new())
      config = thread("paused-update-as-node")

      assert {:interrupted, _interrupt} = Compiled.invoke(graph, %{order_id: "A-1"}, config: config)
      assert {:ok, _config} = Compiled.update_state(graph, config, %{approved: "yes"}, as_node: :review)
      assert {:ok, %{next: ["send"], interrupts: []}} = Compiled.get_state(graph, config)

      assert {:ok, %{approved: "yes", sent: "Refund for A-1."}} = Compiled.invoke(graph, %{}, config: config)
    end

    test "a resume that fails leaves only the pause, and the next pause replaces it" do
      graph =
        Graph.new()
        |> Graph.add_node(:review, fn _state ->
          case Graph.interrupt("Refund?") do
            "yes" -> %{amount: Graph.interrupt("How much?")}
            answer -> {:error, Error.new(:invalid_answer, "can't read #{inspect(answer)}")}
          end
        end)
        |> Graph.add_edge(Graph.start(), :review)
        |> Graph.add_edge(:review, Graph.end_node())
        |> Graph.compile!(checkpointer: CheckpointETS.new())

      config = thread("paused-resume-fails")

      assert {:interrupted, %{value: "Refund?"}} = Compiled.invoke(graph, %{}, config: config)
      assert {:error, %Error{type: :invalid_answer}} = Compiled.resume(graph, "maybe", config: config)

      assert {:ok, %{pending_writes: [{_task, "__interrupt__", %{value: "Refund?"}}]}} =
               Compiled.get_state(graph, config)

      assert {:interrupted, %{value: "How much?"}} = Compiled.resume(graph, "yes", config: config)

      assert {:ok, %{pending_writes: [{_task, "__interrupt__", %{value: "How much?"}}]}} =
               Compiled.get_state(graph, config)

      assert {:ok, %{amount: 20}} = Compiled.resume(graph, 20, config: config)
    end
  end

  describe "a step that stopped partway" do
    test "continuing after a failure runs the next nodes of the nodes that finished" do
      graph =
        branches_graph(fn state ->
          if state[:fixed], do: %{log: ["b"]}, else: {:error, Error.new(:outage, "b failed")}
        end)

      config = thread("partway-failure")

      assert {:error, %Error{type: :outage}} = Compiled.invoke(graph, %{log: []}, config: config)
      assert {:ok, %{log: ["a", "b", "after a"]}} = Compiled.invoke(graph, %{fixed: true}, config: config)
    end

    test "resuming runs the next nodes of the nodes that finished beside the pause" do
      graph = branches_graph(fn _state -> %{log: ["b: " <> Graph.interrupt("Go on?")]} end)
      config = thread("partway-pause")

      assert {:interrupted, _interrupt} = Compiled.invoke(graph, %{log: []}, config: config)
      assert {:ok, %{log: ["a", "b: yes", "after a"]}} = Compiled.resume(graph, "yes", config: config)
    end

    test "the gotos, sends and guarded edges of finished nodes still route" do
      failures = :counters.new(1, [])

      graph =
        Graph.new()
        |> Graph.add_reducer(:log, &(&1 ++ &2))
        |> Graph.add_node(:classify, fn _state -> %Command{update: %{log: ["classify"]}, goto: :billing} end,
          destinations: [:billing, :shipping]
        )
        |> Graph.add_node(:split, fn _state ->
          [%Send{node: :check, update: %{order_id: "A-1"}}, %Send{node: :check, update: %{order_id: "A-2"}}]
        end)
        |> Graph.add_node(:grade, fn _state -> %{grade: :a, log: ["grade"]} end)
        |> Graph.add_node(:flaky, fn _state ->
          :counters.add(failures, 1, 1)

          if :counters.get(failures, 1) == 1,
            do: {:error, Error.new(:outage, "flaky failed")},
            else: %{log: ["flaky"]}
        end)
        |> Graph.add_node(:billing, fn _state -> %{log: ["billing"]} end)
        |> Graph.add_node(:shipping, fn _state -> %{log: ["shipping"]} end)
        |> Graph.add_node(:check, fn %{order_id: order_id} -> %{log: ["check #{order_id}"]} end)
        |> Graph.add_node(:celebrate, fn _state -> %{log: ["celebrate"]} end)
        |> Graph.add_edge(Graph.start(), :classify)
        |> Graph.add_edge(Graph.start(), :split)
        |> Graph.add_edge(Graph.start(), :grade)
        |> Graph.add_edge(Graph.start(), :flaky)
        |> Graph.add_edge(:classify, :shipping)
        |> Graph.add_edge(:grade, :celebrate, when: %{grade: :a})
        |> Graph.compile!(checkpointer: CheckpointETS.new())

      config = thread("partway-routes")

      assert {:error, %Error{type: :outage}} = Compiled.invoke(graph, %{log: []}, config: config)
      assert {:ok, %{log: log}} = Compiled.invoke(graph, %{}, config: config)

      assert Enum.sort(log) ==
               Enum.sort(["classify", "grade", "flaky", "billing", "check A-1", "check A-2", "celebrate"])
    end

    test "continuing runs every Send that didn't finish, and get_state lists each" do
      attempts = :ets.new(:attempts, [:public, :set])
      graph = map_reduce_graph(attempts, fn item, attempt -> item in ["b", "c"] and attempt == 1 end)
      config = thread("partway-sends")

      assert {:error, %Error{type: :node_error}} =
               Compiled.invoke(graph, %{items: ["a", "b", "c"], results: []}, config: config)

      assert {:ok, snapshot} = Compiled.get_state(graph, config)

      assert snapshot.next_tasks == [
               %{"node" => "work", "update" => %{item: "b"}},
               %{"node" => "work", "update" => %{item: "c"}}
             ]

      assert {:ok, %{results: results}} = Compiled.invoke(graph, %{}, config: config)
      assert Enum.sort(results) == ["a", "b", "c"]
      assert Enum.sort(:ets.tab2list(attempts)) == [{"a", 1}, {"b", 2}, {"c", 2}]
    end

    test "of identical Sends, continuing runs only the one that didn't finish" do
      attempts = :ets.new(:attempts, [:public, :set])

      # Whichever of the two "refund" tasks runs second fails the first time.
      graph = map_reduce_graph(attempts, fn item, attempt -> item == "refund" and attempt == 2 end)
      config = thread("partway-identical-sends")

      assert {:error, %Error{type: :node_error}} =
               Compiled.invoke(graph, %{items: ["refund", "refund", "ship"], results: []}, config: config)

      assert {:ok, %{next_tasks: [%{"node" => "work", "update" => %{item: "refund"}}]}} =
               Compiled.get_state(graph, config)

      assert {:ok, %{results: results}} = Compiled.invoke(graph, %{}, config: config)
      assert Enum.sort(results) == ["refund", "refund", "ship"]
      assert Enum.sort(:ets.tab2list(attempts)) == [{"refund", 3}, {"ship", 1}]
    end

    test "a replay from the snapshot config that stops again still routes from the nodes that finished" do
      failures = :counters.new(1, [])

      graph =
        branches_graph(fn _state ->
          :counters.add(failures, 1, 1)

          if :counters.get(failures, 1) <= 2,
            do: {:error, Error.new(:outage, "b failed")},
            else: %{log: ["b"]}
        end)

      config = thread("partway-fork-fails-again")

      assert {:error, %Error{type: :outage}} = Compiled.invoke(graph, %{log: []}, config: config)
      {:ok, snapshot} = Compiled.get_state(graph, config)
      assert {:error, %Error{type: :outage}} = Compiled.invoke(graph, %{}, config: snapshot.config)

      assert {:ok, %{log: ["a", "b", "after a"]}} = Compiled.invoke(graph, %{}, config: config)
    end

    test "a replay from the snapshot config that pauses again still routes from the nodes that finished" do
      graph = branches_graph(fn _state -> %{log: ["b: " <> Graph.interrupt("Go on?")]} end)
      config = thread("partway-fork-pauses-again")

      assert {:interrupted, _interrupt} = Compiled.invoke(graph, %{log: []}, config: config)
      {:ok, snapshot} = Compiled.get_state(graph, config)
      assert {:interrupted, _interrupt} = Compiled.invoke(graph, %{}, config: snapshot.config)

      assert {:ok, %{log: ["a", "b: yes", "after a"]}} = Compiled.resume(graph, "yes", config: config)
    end

    test "a goto replaces the edges of its own node only" do
      graph =
        Graph.new()
        |> Graph.add_reducer(:log, &(&1 ++ &2))
        |> Graph.add_node(:classify, fn _state -> %Command{update: %{log: ["classify"]}, goto: :billing} end,
          destinations: [:billing]
        )
        |> Graph.add_node(:lookup, fn _state -> %{log: ["lookup"]} end)
        |> Graph.add_node(:billing, fn _state -> %{log: ["billing"]} end)
        |> Graph.add_node(:reply, fn _state -> %{log: ["reply"]} end)
        |> Graph.add_edge(Graph.start(), :classify)
        |> Graph.add_edge(Graph.start(), :lookup)
        |> Graph.add_edge(:lookup, :reply)
        |> Graph.compile!()

      assert {:ok, %{log: log}} = Compiled.invoke(graph, %{log: []})
      assert Enum.sort(log) == ["billing", "classify", "lookup", "reply"]
    end
  end

  describe "update_state on a failed thread" do
    test "keeps the failed node to run and applies the finished nodes' writes once" do
      graph =
        branches_graph(fn state ->
          if state[:fixed], do: %{log: ["b"]}, else: {:error, Error.new(:outage, "b failed")}
        end)

      config = thread("failed-update")

      assert {:error, %Error{type: :outage}} = Compiled.invoke(graph, %{log: []}, config: config)
      assert {:ok, _config} = Compiled.update_state(graph, config, %{fixed: true})
      assert {:ok, %{values: %{log: ["a"], fixed: true}, next: ["b"]}} = Compiled.get_state(graph, config)

      assert {:ok, %{log: ["a", "b", "after a"]}} = Compiled.invoke(graph, %{}, config: config)
    end

    test "an update as the failed node is its result: it doesn't run again, and its branch arrives" do
      runs = :counters.new(1, [])

      graph =
        Graph.new()
        |> Graph.add_reducer(:log, &(&1 ++ &2))
        |> Graph.add_node(:a, fn _state -> %{log: ["a"]} end)
        |> Graph.add_node(:b, fn _state ->
          :counters.add(runs, 1, 1)
          {:error, Error.new(:outage, "b failed")}
        end)
        |> Graph.add_node(:c, fn _state -> %{log: ["c"]} end)
        |> Graph.add_edge(Graph.start(), :a)
        |> Graph.add_edge(Graph.start(), :b)
        |> Graph.add_join([:a, :b], :c)
        |> Graph.add_edge(:c, Graph.end_node())
        |> Graph.compile!(checkpointer: CheckpointETS.new())

      config = thread("failed-update-as-node")

      assert {:error, %Error{type: :outage}} = Compiled.invoke(graph, %{log: []}, config: config)
      assert {:ok, _config} = Compiled.update_state(graph, config, %{log: ["b, by hand"]}, as_node: :b)
      assert {:ok, %{next: ["c"], values: %{log: ["a", "b, by hand"]}}} = Compiled.get_state(graph, config)

      assert {:ok, %{log: ["a", "b, by hand", "c"]}} = Compiled.invoke(graph, %{}, config: config)
      assert :counters.get(runs, 1) == 1
    end

    test "an update as a node that finished beside the failed one replaces its result for routing" do
      graph =
        Graph.new()
        |> Graph.add_reducer(:log, &(&1 ++ &2))
        |> Graph.add_node(:grade, fn _state -> %{grade: :a, log: ["graded"]} end)
        |> Graph.add_node(:b, fn state ->
          if state[:fixed], do: %{log: ["b"]}, else: {:error, Error.new(:outage, "b failed")}
        end)
        |> Graph.add_node(:celebrate, fn _state -> %{log: ["celebrate"]} end)
        |> Graph.add_node(:review, fn _state -> %{log: ["review"]} end)
        |> Graph.add_edge(Graph.start(), :grade)
        |> Graph.add_edge(Graph.start(), :b)
        |> Graph.add_edge(:grade, :celebrate, when: %{grade: :a})
        |> Graph.add_edge(:grade, :review, when: %{grade: :b})
        |> Graph.compile!(checkpointer: CheckpointETS.new())

      config = thread("failed-update-as-finished-node")

      assert {:error, %Error{type: :outage}} = Compiled.invoke(graph, %{log: []}, config: config)
      assert {:ok, _config} = Compiled.update_state(graph, config, %{grade: :b, fixed: true}, as_node: :grade)
      assert {:ok, %{next: ["b"]}} = Compiled.get_state(graph, config)
      assert {:ok, %{log: ["graded", "b", "review"]}} = Compiled.invoke(graph, %{}, config: config)
    end
  end

  test "a struct resume value answers the pending interrupt" do
    graph =
      Graph.new()
      |> Graph.add_node(:schedule, fn _state -> %{date: Graph.interrupt("Which day?")} end)
      |> Graph.add_edge(Graph.start(), :schedule)
      |> Graph.add_edge(:schedule, Graph.end_node())
      |> Graph.compile!(checkpointer: CheckpointETS.new())

    config = thread("struct-resume")

    assert {:interrupted, _interrupt} = Compiled.invoke(graph, %{}, config: config)
    assert {:ok, %{date: ~D[2026-10-12]}} = Compiled.resume(graph, ~D[2026-10-12], config: config)
  end

  defp refund_graph(saver, opts \\ []) do
    Graph.new()
    |> Graph.add_reducer(:log, &(&1 ++ &2))
    |> Graph.add_node(:issue_refund, fn state -> %{log: ["refund #{state.order_id}"]} end)
    |> Graph.add_node(:notify, &notify/2)
    |> Graph.add_edge(Graph.start(), :issue_refund)
    |> Graph.add_edge(:issue_refund, :notify)
    |> Graph.add_edge(:notify, Graph.end_node())
    |> Graph.compile!([checkpointer: saver] ++ opts)
  end

  defp notify(state, runtime) do
    if pid = (runtime.context || %{})[:stop_in_notify] do
      send(pid, :notify_started)
      Process.sleep(:infinity)
    end

    %{log: ["notified #{state.order_id}"]}
  end

  # `a` finishes in the first step, beside `b`; `after a` follows `a`.
  defp branches_graph(b) do
    Graph.new()
    |> Graph.add_reducer(:log, &(&1 ++ &2))
    |> Graph.add_node(:a, fn _state -> %{log: ["a"]} end)
    |> Graph.add_node(:b, b)
    |> Graph.add_node(:after_a, fn _state -> %{log: ["after a"]} end)
    |> Graph.add_edge(Graph.start(), :a)
    |> Graph.add_edge(Graph.start(), :b)
    |> Graph.add_edge(:a, :after_a)
    |> Graph.add_edge(:after_a, Graph.end_node())
    |> Graph.add_edge(:b, Graph.end_node())
    |> Graph.compile!(checkpointer: CheckpointETS.new())
  end

  # Sends one `work` task per item; `fail?.(item, attempt)` says which runs
  # of `work` fail, counting the runs of each item in `attempts`.
  defp map_reduce_graph(attempts, fail?) do
    Graph.new()
    |> Graph.add_reducer(:results, &(&1 ++ &2))
    |> Graph.add_node(:split, fn %{items: items} -> Enum.map(items, &%Send{node: :work, update: %{item: &1}}) end)
    |> Graph.add_node(:work, fn %{item: item} ->
      attempt = :ets.update_counter(attempts, item, 1, {item, 0})
      if fail?.(item, attempt), do: {:error, "#{item} failed"}, else: %{results: [item]}
    end)
    |> Graph.add_edge(Graph.start(), :split)
    |> Graph.add_edge(:work, Graph.end_node())
    |> Graph.compile!(checkpointer: CheckpointETS.new())
  end

  defp approval_graph(saver) do
    Graph.new()
    |> Graph.add_node(:draft, fn state -> %{reply: "Refund for #{state.order_id}."} end)
    |> Graph.add_node(:review, fn _state -> %{approved: Graph.interrupt("Send this reply?")} end)
    |> Graph.add_node(:send, fn state -> %{sent: state.reply} end)
    |> Graph.add_edge(Graph.start(), :draft)
    |> Graph.add_edge(:draft, :review)
    |> Graph.add_edge(:review, :send)
    |> Graph.add_edge(:send, Graph.end_node())
    |> Graph.compile!(checkpointer: saver)
  end

  # Runs the graph in another process and kills that process while `notify`
  # runs, the way a crash or a deploy stops a run. The checkpoint tables
  # belong to the test process, so they survive.
  defp crash_in_notify(run) do
    test = self()
    {pid, ref} = spawn_monitor(fn -> run.(%{stop_in_notify: test}) end)
    # However long the run takes to get there, unless it ends first.
    receive do
      :notify_started -> :ok
      {:DOWN, ^ref, :process, ^pid, reason} -> flunk("the run ended before notify started: #{inspect(reason)}")
    end

    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^ref, :process, ^pid, reason} -> assert reason == :killed
    end
  end

  defp thread(id), do: %{"configurable" => %{"thread_id" => id}}
end
