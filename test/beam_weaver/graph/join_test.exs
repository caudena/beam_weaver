defmodule BeamWeaver.Graph.JoinTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Checkpoint
  alias BeamWeaver.Checkpoint.ETS, as: CheckpointETS
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Graph
  alias BeamWeaver.Graph.Compiled

  defp trail_graph do
    Graph.new()
    |> Graph.add_reducer(:trail, &(&1 ++ &2))
  end

  defp step(name), do: fn _state -> %{trail: [name]} end

  test "a join fires when its branches finish in different steps" do
    graph =
      trail_graph()
      |> Graph.add_node(:a, step("a"))
      |> Graph.add_node(:a2, step("a2"))
      |> Graph.add_node(:b, step("b"))
      |> Graph.add_node(:c, fn state -> %{trail: ["c"], seen: Enum.sort(state.trail)} end)
      |> Graph.add_edge(Graph.start(), :a)
      |> Graph.add_edge(:a, :a2)
      |> Graph.add_edge(Graph.start(), :b)
      |> Graph.add_join([:a2, :b], :c)
      |> Graph.add_edge(:c, Graph.end_node())
      |> Graph.compile!()

    assert {:ok, %{trail: ["a", "b", "a2", "c"], seen: ["a", "a2", "b"]}} =
             Compiled.invoke(graph, %{trail: []})
  end

  test "deps: waits for every dependency, however many steps each branch takes" do
    graph =
      trail_graph()
      |> Graph.add_node(:a, step("a"))
      |> Graph.add_node(:a2, step("a2"))
      |> Graph.add_node(:a3, step("a3"))
      |> Graph.add_node(:b, step("b"))
      |> Graph.add_node(:c, step("c"), deps: [:a3, :b])
      |> Graph.add_edge(Graph.start(), :a)
      |> Graph.add_edge(:a, :a2)
      |> Graph.add_edge(:a2, :a3)
      |> Graph.add_edge(Graph.start(), :b)
      |> Graph.add_edge(:c, Graph.end_node())
      |> Graph.compile!()

    assert {:ok, %{trail: ["a", "b", "a2", "a3", "c"]}} = Compiled.invoke(graph, %{trail: []})
  end

  test "a join in a loop fires once per round" do
    graph =
      trail_graph()
      |> Graph.add_reducer(:rounds, &+/2)
      |> Graph.add_node(:a, step("a"))
      |> Graph.add_node(:b, step("b"))
      |> Graph.add_node(:b2, step("b2"))
      |> Graph.add_node(:c, fn _state -> %{trail: ["c"], rounds: 1} end)
      |> Graph.add_edge(Graph.start(), :a)
      |> Graph.add_edge(Graph.start(), :b)
      |> Graph.add_edge(:b, :b2)
      |> Graph.add_join([:a, :b2], :c)
      |> Graph.add_edge(:c, :a, when: fn _update, state -> state.rounds < 2 end)
      |> Graph.add_edge(:c, :b, when: fn _update, state -> state.rounds < 2 end)
      |> Graph.compile!()

    assert {:ok, %{rounds: 2, trail: trail}} = Compiled.invoke(graph, %{trail: [], rounds: 0})
    assert Enum.count(trail, &(&1 == "c")) == 2
    assert List.last(trail) == "c"
  end

  test "join progress is internal: nodes and results don't see it" do
    parent = self()

    graph =
      Graph.new()
      |> Graph.add_node(:a, fn _state -> %{a: 1} end)
      |> Graph.add_node(:a2, fn state ->
        send(parent, {:a2_state_keys, Map.keys(state)})
        %{a2: 1}
      end)
      |> Graph.add_node(:b, fn _state -> %{b: 1} end)
      |> Graph.add_node(:c, fn state ->
        send(parent, {:c_state_keys, Map.keys(state)})
        %{c: 1}
      end)
      |> Graph.add_edge(Graph.start(), :a)
      |> Graph.add_edge(:a, :a2)
      |> Graph.add_edge(Graph.start(), :b)
      |> Graph.add_join([:a2, :b], :c)
      |> Graph.add_edge(:c, Graph.end_node())
      |> Graph.compile!()

    assert {:ok, %{a: 1, a2: 1, b: 1, c: 1} = result} = Compiled.invoke(graph, %{})
    assert Enum.all?(Map.keys(result), &is_atom/1)

    # `b` has arrived at the join while `a2` runs.
    assert_receive {:a2_state_keys, a2_keys}
    assert_receive {:c_state_keys, c_keys}
    refute Enum.any?(a2_keys ++ c_keys, &(is_binary(&1) and String.starts_with?(&1, "__barrier__:")))
  end

  test "a join still fires when the thread continues after one of its branches failed" do
    saver = CheckpointETS.new()
    parent = self()
    config = %{"configurable" => %{"thread_id" => "join-after-failure"}}

    graph =
      trail_graph()
      |> Graph.add_node(:a, fn _state ->
        send(parent, :a_ran)
        %{trail: ["a"]}
      end)
      |> Graph.add_node(:b, fn state ->
        if state[:b_ok], do: %{trail: ["b"]}, else: {:error, Error.new(:outage, "b failed")}
      end)
      |> Graph.add_node(:c, step("c"))
      |> Graph.add_edge(Graph.start(), :a)
      |> Graph.add_edge(Graph.start(), :b)
      |> Graph.add_join([:a, :b], :c)
      |> Graph.add_edge(:c, Graph.end_node())
      |> Graph.compile!(checkpointer: saver)

    assert {:error, %Error{type: :outage}} = Compiled.invoke(graph, %{trail: []}, config: config)
    assert_receive :a_ran

    assert {:ok, %{trail: ["a", "b", "c"]}} = Compiled.invoke(graph, %{b_ok: true}, config: config)
    refute_receive :a_ran, 50
  end

  test "join progress is saved with the thread, so a paused branch can finish later" do
    saver = CheckpointETS.new()
    config = %{"configurable" => %{"thread_id" => "join-across-runs"}}

    graph =
      trail_graph()
      |> Graph.add_node(:a, step("a"))
      |> Graph.add_node(:b, step("b"))
      |> Graph.add_node(:approve, fn _state -> %{trail: ["approved: #{Graph.interrupt("ok?")}"]} end)
      |> Graph.add_node(:c, step("c"))
      |> Graph.add_edge(Graph.start(), :a)
      |> Graph.add_edge(Graph.start(), :b)
      |> Graph.add_edge(:b, :approve)
      |> Graph.add_join([:a, :approve], :c)
      |> Graph.add_edge(:c, Graph.end_node())
      |> Graph.compile!(checkpointer: saver)

    assert {:interrupted, %{value: "ok?"}} = Compiled.invoke(graph, %{trail: []}, config: config)

    assert {:ok, %{trail: ["a", "b", "approved: yes", "c"]}} =
             Compiled.resume(graph, "yes", config: config)
  end

  describe "update_state keeps join progress" do
    test "on a thread paused by an interrupt" do
      graph = paused_join_graph(fn _state -> %{trail: ["approved: #{Graph.interrupt("ok?")}"]} end)
      config = %{"configurable" => %{"thread_id" => "join-update-paused"}}

      assert {:interrupted, _interrupt} = Compiled.invoke(graph, %{trail: []}, config: config)
      assert {:ok, _config} = Compiled.update_state(graph, config, %{note: "checked"})

      assert {:ok, %{trail: ["a", "b", "approved: yes", "c"], note: "checked"}} =
               Compiled.resume(graph, "yes", config: config)
    end

    test "on a thread stopped at a breakpoint" do
      graph = paused_join_graph(step("approved"), interrupt_before: [:approve])
      config = %{"configurable" => %{"thread_id" => "join-update-breakpoint"}}

      assert {:interrupted, %{nodes: ["approve"]}} = Compiled.invoke(graph, %{trail: []}, config: config)
      assert {:ok, _config} = Compiled.update_state(graph, config, %{note: "checked"})

      assert {:ok, %{trail: ["a", "b", "approved", "c"], note: "checked"}} =
               Compiled.resume(graph, nil, config: config)
    end

    test "and an update as an upstream node arrives at the join" do
      graph = paused_join_graph(step("approved"), interrupt_before: [:approve])
      config = %{"configurable" => %{"thread_id" => "join-update-as-node"}}

      assert {:interrupted, %{nodes: ["approve"]}} = Compiled.invoke(graph, %{trail: []}, config: config)
      assert {:ok, _config} = Compiled.update_state(graph, config, %{trail: ["approved by hand"]}, as_node: :approve)
      assert {:ok, %{next: ["c"]}} = Compiled.get_state(graph, config)

      assert {:ok, %{trail: ["a", "b", "approved by hand", "c"]}} = Compiled.invoke(graph, %{}, config: config)
    end
  end

  describe "the run counts of guarded edges" do
    test "carry over an update_state" do
      graph = review_loop(interrupt_after: [:review])
      config = %{"configurable" => %{"thread_id" => "edge-runs-update"}}

      assert {:interrupted, %{nodes: ["review"]}} = Compiled.invoke(graph, %{reviews: 0}, config: config)
      assert {:ok, %{next: ["review"]}} = Compiled.get_state(graph, config)

      # The loop has used its one run, so the update, as `review` asking for
      # another round, takes the default edge.
      assert {:ok, _config} = Compiled.update_state(graph, config, %{status: :again})
      assert {:ok, %{next: ["done"]}} = Compiled.get_state(graph, config)
      assert {:ok, %{reviews: 1, done: true}} = Compiled.resume(graph, nil, config: config)
    end
  end

  test "bulk_update_state keeps join progress in the saved state" do
    saver = CheckpointETS.new()
    graph = paused_join_graph(step("approved"), checkpointer: saver, interrupt_before: [:approve])
    config = %{"configurable" => %{"thread_id" => "join-bulk-update"}}

    assert {:interrupted, %{nodes: ["approve"]}} = Compiled.invoke(graph, %{trail: []}, config: config)
    arrivals = join_progress(saver, config)
    assert arrivals != []

    assert {:ok, _config} = Compiled.bulk_update_state(graph, config, [[%{note: "checked"}]])
    assert join_progress(saver, config) == arrivals
  end

  # The joins' arrivals saved in the thread's latest checkpoint.
  defp join_progress(saver, config) do
    %{checkpoint: %{"channel_values" => values}} = Checkpoint.get_tuple(saver, config)
    Enum.filter(values, fn {key, _arrived} -> match?("__barrier__:" <> _join, key) end)
  end

  # `a` and `b` start together; `approve` follows `b`; `c` joins `a` and `approve`.
  defp paused_join_graph(approve, opts \\ []) do
    trail_graph()
    |> Graph.add_node(:a, step("a"))
    |> Graph.add_node(:b, step("b"))
    |> Graph.add_node(:approve, approve)
    |> Graph.add_node(:c, step("c"))
    |> Graph.add_edge(Graph.start(), :a)
    |> Graph.add_edge(Graph.start(), :b)
    |> Graph.add_edge(:b, :approve)
    |> Graph.add_join([:a, :approve], :c)
    |> Graph.add_edge(:c, Graph.end_node())
    |> Graph.compile!(Keyword.put_new(opts, :checkpointer, CheckpointETS.new()))
  end

  # `review` asks for another round each time; its loop edge may run once.
  defp review_loop(opts) do
    Graph.new()
    |> Graph.add_reducer(:reviews, &+/2)
    |> Graph.add_node(:review, fn _state -> %{reviews: 1, status: :again} end)
    |> Graph.add_node(:done, fn _state -> %{done: true} end)
    |> Graph.add_edge(Graph.start(), :review)
    |> Graph.add_edge(:review, :review, when: %{status: :again}, max_runs: 1)
    |> Graph.add_edge(:review, :done, default: true)
    |> Graph.add_edge(:done, Graph.end_node())
    |> Graph.compile!([checkpointer: CheckpointETS.new()] ++ opts)
  end
end
