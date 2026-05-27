defmodule BeamWeaver.Graph.DAGAPITest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Graph
  alias BeamWeaver.Graph.Compiled

  test "start and end sentinels define graph boundaries" do
    graph =
      Graph.new()
      |> Graph.add_node(:hello, fn _state -> %{hello: true} end)
      |> Graph.add_edge(Graph.start(), :hello)
      |> Graph.add_edge(:hello, Graph.end_node())
      |> Graph.compile!()

    assert {:ok, %{hello: true}} = Compiled.invoke(graph, %{})
  end

  test "node deps support fan-in with dependency-gated final work" do
    graph =
      Graph.new()
      |> Graph.add_reducer(:reviews, fn left, right -> Map.merge(left, right) end)
      |> Graph.add_node(:plan, fn _state -> %{plan: "research"} end)
      |> Graph.add_node(:facts, fn state -> %{facts: state.plan <> ":facts"} end, deps: :plan)
      |> Graph.add_node(:market, fn state -> %{market: state.plan <> ":market"} end, deps: :plan)
      |> Graph.add_node(
        :facts_check,
        fn state ->
          %{status: :accepted, value: state.facts}
        end,
        deps: :facts,
        output: [:reviews, :facts]
      )
      |> Graph.add_node(
        :market_check,
        fn state ->
          %{status: :accepted, value: state.market}
        end,
        deps: :market,
        output: [:reviews, :market]
      )
      |> Graph.add_node(
        :final,
        fn state ->
          %{summary: [state.reviews.facts.value, state.reviews.market.value]}
        end,
        deps: [:facts_check, :market_check],
        when: %{status: :accepted}
      )
      |> Graph.add_edge(Graph.start(), :plan)
      |> Graph.add_edge(:final, Graph.end_node())
      |> Graph.compile!()

    assert {:ok,
            %{
              reviews: %{
                facts: %{status: :accepted, value: "research:facts"},
                market: %{status: :accepted, value: "research:market"}
              },
              summary: ["research:facts", "research:market"]
            }} = Compiled.invoke(graph, %{})
  end

  test "when constraints support subset, range, nested map, predicate, and default edges" do
    graph =
      Graph.new()
      |> Graph.add_node(:review, fn state ->
        %{status: state.status, attempt: state.attempt, meta: %{score: state.score}}
      end)
      |> Graph.add_node(:retry, fn _state -> %{routed: :retry} end)
      |> Graph.add_node(:final, fn _state -> %{routed: :final} end)
      |> Graph.add_edge(Graph.start(), :review)
      |> Graph.add_edge(:review, :retry, when: %{status: :needs_revision, attempt: 1..2, meta: %{score: 50..100}})
      |> Graph.add_edge(:review, :final, when: fn output -> output.status == :accepted end)
      |> Graph.add_edge(:review, :final, default: true)
      |> Graph.add_edge(:retry, Graph.end_node())
      |> Graph.add_edge(:final, Graph.end_node())
      |> Graph.compile!()

    assert {:ok, %{routed: :retry}} =
             Compiled.invoke(graph, %{status: :needs_revision, attempt: 2, score: 75})

    assert {:ok, %{routed: :final}} =
             Compiled.invoke(graph, %{status: :needs_revision, attempt: 3, score: 75})

    assert {:ok, %{routed: :final}} =
             Compiled.invoke(graph, %{status: :accepted, attempt: 1, score: 75})
  end

  test "max_runs limits guarded retry edges" do
    graph =
      Graph.new()
      |> Graph.add_reducer(:count, &+/2)
      |> Graph.add_node(:loop, fn _state -> %{count: 1, status: :again} end)
      |> Graph.add_edge(Graph.start(), :loop)
      |> Graph.add_edge(:loop, :loop, when: %{status: :again}, max_runs: 2)
      |> Graph.add_edge(:loop, Graph.end_node(), default: true)
      |> Graph.compile!()

    assert {:ok, %{count: 3}} = Compiled.invoke(graph, %{count: 0}, recursion_limit: 10)
  end
end
