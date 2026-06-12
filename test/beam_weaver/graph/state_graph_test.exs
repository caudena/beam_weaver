defmodule BeamWeaver.Graph.StateGraphTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Graph
  alias BeamWeaver.Graph.Compiled
  alias BeamWeaver.Graph.Send

  defmodule InvalidCheckpointer do
    defstruct [:name]
  end

  test "compile rejects invalid node callables before runtime" do
    graph =
      Graph.new()
      |> Graph.add_node(:bad, :not_a_node)
      |> Graph.add_edge(Graph.start(), :bad)

    assert {:error,
            %{
              type: :invalid_graph,
              message: "graph contains invalid node callables",
              details: %{invalid: [%{node: "bad", callable: ":not_a_node"}]}
            }} = Graph.compile(graph)
  end

  test "guarded edges accept normal Elixir predicates" do
    graph =
      Graph.new()
      |> Graph.add_node(:route, fn _state -> %{status: :done} end)
      |> Graph.add_node(:done, fn _state -> %{done: true} end)
      |> Graph.add_edge(Graph.start(), :route)
      |> Graph.add_edge(:route, :done, when: fn output -> output.status == :done end)
      |> Graph.add_edge(:done, Graph.end_node())
      |> Graph.compile!()

    assert {:ok, %{done: true}} = Compiled.invoke(graph, %{})
  end

  test "compile rejects invalid reducer arities from graph options" do
    graph =
      Graph.new(reducers: %{items: fn value -> value end})
      |> Graph.add_node(:ok, fn state -> state end)
      |> Graph.add_edge(Graph.start(), :ok)

    assert {:error,
            %{
              type: :invalid_graph,
              message: "graph contains invalid reducers",
              details: %{invalid: [%{key: :items, reducer: "function/1"}]}
            }} = Graph.compile(graph)
  end

  test "compile rejects edges that reference undeclared nodes" do
    graph =
      Graph.new()
      |> Graph.add_node(:start, fn state -> state end)
      |> Graph.add_edge(Graph.start(), :start)
      |> Graph.add_edge(:unknown, :start)
      |> Graph.add_edge(:start, Graph.end_node())

    assert {:error,
            %{
              type: :invalid_graph,
              message: "graph references missing nodes",
              details: %{missing: ["unknown"]}
            }} = Graph.compile(graph)
  end

  test "compile rejects invalid checkpointer adapters before runtime" do
    graph =
      Graph.new()
      |> Graph.add_node(:ok, fn state -> state end)
      |> Graph.add_edge(Graph.start(), :ok)
      |> Graph.add_edge(:ok, Graph.end_node())

    assert {:error,
            %{
              type: :invalid_checkpointer,
              message: "graph checkpointer must implement BeamWeaver.Checkpoint.Saver"
            }} = Graph.compile(graph, checkpointer: %{not: :a_saver})

    assert {:error,
            %{
              type: :invalid_checkpointer,
              message: "graph checkpointer must implement BeamWeaver.Checkpoint.Saver"
            }} = Graph.compile(graph, checkpointer: %InvalidCheckpointer{name: "bad"})

    assert_raise ArgumentError,
                 "graph checkpointer must implement BeamWeaver.Checkpoint.Saver",
                 fn ->
                   Graph.compile!(graph, checkpointer: %InvalidCheckpointer{name: "bad"})
                 end
  end

  test "add_sequence wires ordered nodes without requiring Python-style builders" do
    graph =
      Graph.new()
      |> Graph.add_sequence([
        {:first, fn state -> %{steps: Map.get(state, :steps, []) ++ [:first]} end},
        {:second, fn state -> %{steps: state.steps ++ [:second]} end},
        {:third, fn state -> %{steps: state.steps ++ [:third]} end}
      ])
      |> Graph.add_edge(Graph.start(), :first)
      |> Graph.add_edge(:third, Graph.end_node())
      |> Graph.compile!()

    assert {:ok, %{steps: [:first, :second, :third]}} = Compiled.invoke(graph, %{steps: []})
  end

  test "waiting edges run a node only after every upstream node has completed" do
    graph =
      Graph.new()
      |> Graph.add_node(:fanout, fn _state ->
        [
          %Send{node: :left},
          %Send{node: :right}
        ]
      end)
      |> Graph.add_node(:left, fn _state -> %{left: true} end)
      |> Graph.add_node(:right, fn _state -> %{right: true} end)
      |> Graph.add_node(:join, fn state -> %{joined: state.left && state.right} end, deps: [:left, :right])
      |> Graph.add_edge(Graph.start(), :fanout)
      |> Graph.add_edge(:join, Graph.end_node())
      |> Graph.compile!()

    assert {:ok, %{joined: true}} = Compiled.invoke(graph, %{})
  end

  test "guarded branches can feed a dependent node after selected branch work" do
    graph =
      Graph.new()
      |> Graph.add_node(:route, fn _state -> %{route: :left} end)
      |> Graph.add_node(:left, fn _state -> %{path: :left} end)
      |> Graph.add_node(:after_branch, fn state -> %{after_branch: state.path} end, deps: :left)
      |> Graph.add_edge(Graph.start(), :route)
      |> Graph.add_edge(:route, :left, when: %{route: :left})
      |> Graph.add_edge(:after_branch, Graph.end_node())
      |> Graph.compile!()

    assert {:ok, %{path: :left, after_branch: :left}} = Compiled.invoke(graph, %{})
  end

  test "conditional entry routing is modeled with an explicit entry router node" do
    # BeamWeaver keeps graph construction explicit: the entry point is a normal
    # node, and guarded edges route using the entry router's output.
    graph =
      Graph.new()
      |> Graph.add_node(:entry_router, fn state -> %{route: state.route} end)
      |> Graph.add_node(:left, fn _state -> %{path: :left} end)
      |> Graph.add_node(:right, fn _state -> %{path: :right} end)
      |> Graph.add_edge(Graph.start(), :entry_router)
      |> Graph.add_edge(:entry_router, :left, when: %{route: :left})
      |> Graph.add_edge(:entry_router, :right, when: %{route: :right})
      |> Graph.add_edge(:left, Graph.end_node())
      |> Graph.add_edge(:right, Graph.end_node())
      |> Graph.compile!()

    assert {:ok, %{route: :left, path: :left}} = Compiled.invoke(graph, %{route: :left})
    assert {:ok, %{route: :right, path: :right}} = Compiled.invoke(graph, %{route: :right})
  end

  test "static validation can reject unreachable nodes without breaking dynamic Send graphs" do
    graph =
      Graph.new()
      |> Graph.add_node(:begin, fn state -> state end)
      |> Graph.add_node(:orphan, fn state -> state end)
      |> Graph.add_edge(Graph.start(), :begin)
      |> Graph.add_edge(:begin, Graph.end_node())

    assert {:ok, _compiled} = Graph.compile(graph)

    assert {:error,
            %{
              type: :invalid_graph,
              message: "graph contains unreachable nodes",
              details: %{nodes: ["orphan"]}
            }} = Graph.compile(graph, validate_static: true)
  end

  test "node specs support runtime injection and input/output projection" do
    graph =
      Graph.new()
      |> Graph.add_node(
        :project,
        fn state, runtime ->
          %{value: state.count + runtime.step + if(runtime.node == "project", do: 1, else: 0)}
        end,
        input: [:count],
        output: :answer,
        metadata: %{purpose: :projection},
        destinations: [:done]
      )
      |> Graph.add_edge(Graph.start(), :project)
      |> Graph.add_edge(:project, Graph.end_node())
      |> Graph.compile!()

    assert {:ok, %{answer: %{value: 3}}} = Compiled.invoke(graph, %{count: 2})

    introspection = Compiled.get_graph(graph)

    assert Map.take(introspection.nodes["project"].metadata, [:purpose]) == %{
             purpose: :projection
           }

    assert introspection.nodes["project"].destinations == ["done"]
  end

  test "compiled graph introspection and renderers expose deterministic metadata" do
    graph =
      Graph.new(output_schema: %{answer: :integer})
      |> Graph.add_channel(:secret, BeamWeaver.Graph.Channels.EphemeralValue, visibility: :private)
      |> Graph.add_node(:answer, fn _state -> %{answer: 42, secret: "hidden"} end)
      |> Graph.add_edge(Graph.start(), :answer)
      |> Graph.add_edge(:answer, Graph.end_node())
      |> Graph.compile!()

    introspection = Compiled.get_graph(graph)
    assert introspection.name == "BeamWeaverGraph"
    assert introspection.output_channels == ["answer"]
    assert "secret" in introspection.hidden_channels

    assert Compiled.draw_mermaid(graph) =~ "graph TD"
    assert Compiled.draw_ascii(graph) =~ "answer"
    assert {:ok, "png:" <> _} = Compiled.draw_png(graph, renderer: &("png:" <> &1))
  end

  test "node defer metadata is inspectable without changing the public scheduler contract" do
    # Upstream reference:
    graph =
      Graph.new(name: "DeferredMetadataGraph")
      |> Graph.add_node(:start, fn _state -> %{started: true} end)
      |> Graph.add_node(:cleanup, fn _state -> %{cleaned: true} end,
        defer: true,
        metadata: %{phase: :cleanup}
      )
      |> Graph.add_edge(:start, :cleanup)
      |> Graph.add_edge(Graph.start(), :start)
      |> Graph.add_edge(:cleanup, Graph.end_node())
      |> Graph.compile!()

    assert {:ok, %{cleaned: true}} = Compiled.invoke(graph, %{})

    cleanup = Compiled.get_graph(graph).nodes["cleanup"]
    assert cleanup.defer == true
    assert cleanup.metadata.phase == :cleanup
    assert Compiled.draw_mermaid(graph) =~ "cleanup"
  end
end
