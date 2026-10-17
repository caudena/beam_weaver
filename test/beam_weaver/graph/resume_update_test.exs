defmodule BeamWeaver.Graph.ResumeUpdateTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Checkpoint.ETS, as: CheckpointETS
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Graph
  alias BeamWeaver.Graph.Channels.BinaryOperatorAggregate
  alias BeamWeaver.Graph.Channels.DeltaChannel
  alias BeamWeaver.Graph.Channels.EphemeralValue
  alias BeamWeaver.Graph.Command
  alias BeamWeaver.Graph.Compiled

  # `log` keeps its writes as deltas, `plain` saves its whole value: both must
  # read the same after a reload.
  defp schema do
    %{
      log:
        Graph.channel(
          {DeltaChannel, fn current, writes -> Enum.reduce(writes, current || [], &(&2 ++ List.wrap(&1))) end}
        ),
      plain: Graph.channel({BinaryOperatorAggregate, &(&1 ++ &2)}, initial: [])
    }
  end

  defp both(marker), do: %{log: [marker], plain: [marker]}

  defp saved!(graph, config) do
    {:ok, snapshot} = Compiled.get_state(graph, config)
    Map.take(snapshot.values, [:log, :plain])
  end

  describe "a Command with resume and update" do
    test "keeps every update while the node pauses again" do
      graph =
        Graph.new(state_schema: schema())
        |> Graph.add_node(:ask, fn _state ->
          answers = for question <- 1..3, do: Graph.interrupt("#{question}")
          both("ask:" <> Enum.join(answers))
        end)
        |> Graph.add_edge(Graph.start(), :ask)
        |> Graph.add_edge(:ask, Graph.end_node())
        |> Graph.compile!(checkpointer: CheckpointETS.new())

      config = thread("resume-update-three")
      assert {:interrupted, _interrupt} = Compiled.invoke(graph, both("in"), config: config)

      assert {:interrupted, _interrupt} =
               Compiled.invoke(graph, %Command{resume: "1", update: both("u1")}, config: config)

      assert saved!(graph, config) == %{log: ["in", "u1"], plain: ["in", "u1"]}

      assert {:interrupted, _interrupt} =
               Compiled.invoke(graph, %Command{resume: "2", update: both("u2")}, config: config)

      expected = ["in", "u1", "u2", "u3", "ask:123"]

      assert {:ok, %{log: ^expected, plain: ^expected}} =
               Compiled.invoke(graph, %Command{resume: "3", update: both("u3")}, config: config)

      assert saved!(graph, config) == %{log: expected, plain: expected}
    end

    test "saves the update when the step completes" do
      graph =
        Graph.new(state_schema: schema())
        |> Graph.add_node(:ask, fn _state -> both("ask:" <> Graph.interrupt("ok?")) end)
        |> Graph.add_edge(Graph.start(), :ask)
        |> Graph.add_edge(:ask, Graph.end_node())
        |> Graph.compile!(checkpointer: CheckpointETS.new())

      config = thread("resume-update-once")
      assert {:interrupted, _interrupt} = Compiled.invoke(graph, both("in"), config: config)

      expected = ["in", "u", "ask:yes"]

      assert {:ok, %{log: ^expected, plain: ^expected}} =
               Compiled.invoke(graph, %Command{resume: "yes", update: both("u")}, config: config)

      assert saved!(graph, config) == %{log: expected, plain: expected}
    end

    test "past a breakpoint keeps the update when a later node pauses" do
      graph =
        Graph.new(state_schema: schema())
        |> Graph.add_node(:a, fn _state -> both("a") end)
        |> Graph.add_node(:b, fn _state -> both("b") end)
        |> Graph.add_node(:c, fn _state -> both("c:" <> Graph.interrupt("ok?")) end)
        |> Graph.add_edge(Graph.start(), :a)
        |> Graph.add_edge(:a, :b)
        |> Graph.add_edge(:b, :c)
        |> Graph.add_edge(:c, Graph.end_node())
        |> Graph.compile!(checkpointer: CheckpointETS.new(), interrupt_before: [:b])

      config = thread("breakpoint-update")
      assert {:interrupted, %{timing: :before}} = Compiled.invoke(graph, both("in"), config: config)

      assert {:interrupted, %{value: "ok?"}} =
               Compiled.invoke(graph, %Command{resume: :go, update: both("u")}, config: config)

      assert saved!(graph, config) == %{log: ["in", "a", "u", "b"], plain: ["in", "a", "u", "b"]}

      expected = ["in", "a", "u", "b", "c:yes"]
      assert {:ok, %{log: ^expected, plain: ^expected}} = Compiled.resume(graph, "yes", config: config)
    end
  end

  describe "a Command with an update and no resume" do
    test "saves the update in the state of every channel" do
      graph = two_step_graph()
      config = thread("command-update-goto")

      assert {:ok, _state} = Compiled.invoke(graph, both("in"), config: config)

      expected = ["in", "a", "cmd", "b"]

      assert {:ok, %{log: ^expected, plain: ^expected}} =
               Compiled.invoke(graph, %Command{update: both("cmd"), goto: :b}, config: config)

      assert saved!(graph, config) == %{log: expected, plain: expected}
    end

    test "on a new thread, the update is in the saved state" do
      graph = two_step_graph()
      config = thread("command-update-new")

      assert {:ok, %{log: ["cmd"], plain: ["cmd"]}} =
               Compiled.invoke(graph, %Command{update: both("cmd")}, config: config)

      assert saved!(graph, config) == %{log: ["cmd"], plain: ["cmd"]}
    end
  end

  describe "new input to a stopped step" do
    test "is saved when the step completes after a failure" do
      failures = :counters.new(1, [])

      graph =
        Graph.new(state_schema: schema())
        |> Graph.add_node(:p, fn _state -> both("p") end)
        |> Graph.add_node(:q, fn _state ->
          :counters.add(failures, 1, 1)
          if :counters.get(failures, 1) == 1, do: {:error, Error.new(:outage, "q failed")}, else: both("q")
        end)
        |> Graph.add_edge(Graph.start(), :p)
        |> Graph.add_edge(Graph.start(), :q)
        |> Graph.compile!(checkpointer: CheckpointETS.new())

      config = thread("input-after-failure")
      assert {:error, %Error{type: :outage}} = Compiled.invoke(graph, both("in-1"), config: config)

      expected = ["in-1", "p", "in-2", "q"]
      assert {:ok, %{log: ^expected, plain: ^expected}} = Compiled.invoke(graph, both("in-2"), config: config)
      assert saved!(graph, config) == %{log: expected, plain: expected}
    end

    test "is saved when the step pauses again, and the next resume keeps it" do
      graph =
        Graph.new(state_schema: schema())
        |> Graph.add_node(:p, fn _state -> both("p") end)
        |> Graph.add_node(:q, fn _state -> both("q:" <> Graph.interrupt("approve?")) end)
        |> Graph.add_edge(Graph.start(), :p)
        |> Graph.add_edge(Graph.start(), :q)
        |> Graph.compile!(checkpointer: CheckpointETS.new())

      config = thread("input-on-pause")
      assert {:interrupted, _interrupt} = Compiled.invoke(graph, both("in-1"), config: config)

      assert {:interrupted, %{value: "approve?"}} = Compiled.invoke(graph, both("in-2"), config: config)
      assert saved!(graph, config) == %{log: ["in-1", "p", "in-2"], plain: ["in-1", "p", "in-2"]}
      assert {:ok, %{next: ["q"], interrupts: [%{value: "approve?"}]}} = Compiled.get_state(graph, config)

      expected = ["in-1", "p", "in-2", "q:yes"]
      assert {:ok, %{log: ^expected, plain: ^expected}} = Compiled.resume(graph, "yes", config: config)
      assert saved!(graph, config) == %{log: expected, plain: expected}
    end

    test "still schedules the nodes that the finished nodes' writes trigger" do
      graph = listener_graph()
      config = thread("input-triggers")

      assert {:error, %Error{type: :outage}} = Compiled.invoke(graph, %{log: []}, config: config)

      assert {:ok, %{log: ["source", "flaky", "heard ready"]}} =
               Compiled.invoke(graph, %{note: "retry"}, config: config)
    end

    test "after update_state, still schedules the nodes that the finished nodes' writes trigger" do
      graph = listener_graph()
      config = thread("update-triggers")

      assert {:error, %Error{type: :outage}} = Compiled.invoke(graph, %{log: []}, config: config)
      assert {:ok, _config} = Compiled.update_state(graph, config, %{note: "retry"})
      assert {:ok, %{log: ["source", "flaky", "heard ready"]}} = Compiled.invoke(graph, %{}, config: config)
    end

    test "keeps the ephemeral values that the finished nodes wrote for the next step" do
      for continue <- [
            &Compiled.invoke(&1, %{log: ["in-2"]}, config: &2),
            fn graph, config ->
              {:ok, _config} = Compiled.update_state(graph, config, %{log: ["in-2"]})
              Compiled.invoke(graph, %{}, config: config)
            end
          ] do
        failures = :counters.new(1, [])
        log = Graph.channel({BinaryOperatorAggregate, &(List.wrap(&1) ++ List.wrap(&2))}, initial: [])

        graph =
          Graph.new(state_schema: %{note: Graph.channel(EphemeralValue), log: log})
          |> Graph.add_node(:p, fn _state -> %{note: "from p"} end)
          |> Graph.add_node(:q, fn _state ->
            :counters.add(failures, 1, 1)
            if :counters.get(failures, 1) == 1, do: {:error, Error.new(:outage, "q failed")}, else: %{log: ["q"]}
          end)
          |> Graph.add_node(:r, fn state -> %{log: [state.note]} end)
          |> Graph.add_edge(Graph.start(), :p)
          |> Graph.add_edge(Graph.start(), :q)
          |> Graph.add_edge(:p, :r)
          |> Graph.compile!(checkpointer: CheckpointETS.new())

        config = thread("ephemeral-#{System.unique_integer([:positive])}")
        assert {:error, %Error{type: :outage}} = Compiled.invoke(graph, %{log: ["in-1"]}, config: config)
        assert {:ok, %{log: ["in-1", "in-2", "q", "from p"]}} = continue.(graph, config)
      end
    end
  end

  describe "answers keyed by interrupt id" do
    test "a task paused at its second question keeps its first answer when another task is answered" do
      graph =
        Graph.new(state_schema: %{log: Graph.channel({BinaryOperatorAggregate, &(&1 ++ &2)}, initial: [])})
        |> Graph.add_node(:a, fn _state -> %{log: ["a:" <> Graph.interrupt("A1") <> "," <> Graph.interrupt("A2")]} end)
        |> Graph.add_node(:b, fn _state -> %{log: ["b:" <> Graph.interrupt("B")]} end)
        |> Graph.add_edge(Graph.start(), :a)
        |> Graph.add_edge(Graph.start(), :b)
        |> Graph.compile!(checkpointer: CheckpointETS.new())

      config = thread("second-question")
      assert {:interrupted, _interrupt} = Compiled.invoke(graph, %{log: []}, config: config)
      {:ok, s0} = Compiled.get_state(graph, config)

      assert {:interrupted, _interrupt} = Compiled.resume(graph, %{by_value(s0, "A1").id => "one"}, config: config)
      {:ok, s1} = Compiled.get_state(graph, config)
      assert s1.interrupts |> Enum.map(& &1.value) |> Enum.sort() == ["A2", "B"]

      assert {:interrupted, _interrupt} = Compiled.resume(graph, %{by_value(s1, "B").id => "ok"}, config: config)
      {:ok, s2} = Compiled.get_state(graph, config)
      assert Enum.map(s2.interrupts, & &1.value) == ["A2"]
      assert s2.next == ["a"]

      assert {:ok, %{log: log}} = Compiled.resume(graph, %{by_value(s2, "A2").id => "two"}, config: config)
      assert Enum.sort(log) == ["a:one,two", "b:ok"]
    end
  end

  describe "a resume from an older stopped checkpoint" do
    test "leaves the branch that already went on from it as it was" do
      asker = fn name -> fn _state -> both("#{name}:" <> Graph.interrupt("#{name}?")) end end

      graph =
        Graph.new(state_schema: schema())
        |> Graph.add_node(:p, fn _state -> both("p") end)
        |> Graph.add_node(:q1, asker.("q1"))
        |> Graph.add_node(:q2, asker.("q2"))
        |> Graph.add_edge(Graph.start(), :p)
        |> Graph.add_edge(Graph.start(), :q1)
        |> Graph.add_edge(Graph.start(), :q2)
        |> Graph.compile!(checkpointer: CheckpointETS.new())

      config = thread("branch-leak")
      assert {:interrupted, _interrupt} = Compiled.invoke(graph, both("in"), config: config)
      {:ok, stopped} = Compiled.get_state(graph, config)
      ids = Map.new(stopped.interrupts, &{&1.node, &1.id})

      assert {:ok, _state} = Compiled.resume(graph, %{ids["q1"] => "yes", ids["q2"] => "yes"}, config: config)
      {:ok, head_a} = Compiled.get_state(graph, config)
      branch_a = Map.take(head_a.values, [:log, :plain])

      assert {:interrupted, %{value: "q2?"}} = Compiled.resume(graph, %{ids["q1"] => "again"}, config: stopped.config)

      assert saved!(graph, head_a.config) == branch_a
      assert saved!(graph, stopped.config) == %{log: ["in"], plain: ["in"]}

      {:ok, branch_b} = Compiled.get_state(graph, config)
      assert branch_b.next == ["q2"]

      assert Map.take(branch_b.values, [:log, :plain]) == %{
               log: ["in", "p", "q1:again"],
               plain: ["in", "p", "q1:again"]
             }

      expected = ["in", "p", "q1:again", "q2:no"]
      assert {:ok, %{log: ^expected, plain: ^expected}} = Compiled.resume(graph, "no", config: config)
      assert saved!(graph, head_a.config) == branch_a
    end
  end

  # `source` and `flaky` start together; `flaky` fails once; `listener` runs
  # when `signal` changes.
  defp listener_graph do
    failures = :counters.new(1, [])

    Graph.new()
    |> Graph.add_reducer(:log, &(&1 ++ &2))
    |> Graph.add_node(:source, fn _state -> %{signal: "ready", log: ["source"]} end)
    |> Graph.add_node(:flaky, fn _state ->
      :counters.add(failures, 1, 1)
      if :counters.get(failures, 1) == 1, do: {:error, Error.new(:outage, "flaky failed")}, else: %{log: ["flaky"]}
    end)
    |> Graph.add_node(:listener, fn state -> %{log: ["heard " <> state.signal]} end, triggers: [:signal])
    |> Graph.add_edge(Graph.start(), :source)
    |> Graph.add_edge(Graph.start(), :flaky)
    |> Graph.add_edge(:listener, Graph.end_node())
    |> Graph.compile!(checkpointer: CheckpointETS.new())
  end

  defp two_step_graph do
    Graph.new(state_schema: schema())
    |> Graph.add_node(:a, fn _state -> both("a") end)
    |> Graph.add_node(:b, fn _state -> both("b") end)
    |> Graph.add_edge(Graph.start(), :a)
    |> Graph.add_edge(:a, Graph.end_node())
    |> Graph.add_edge(:b, Graph.end_node())
    |> Graph.compile!(checkpointer: CheckpointETS.new())
  end

  defp by_value(snapshot, value), do: Enum.find(snapshot.interrupts, &(&1.value == value))

  defp thread(id), do: %{"configurable" => %{"thread_id" => id}}
end
