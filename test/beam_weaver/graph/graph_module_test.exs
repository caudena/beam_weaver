defmodule BeamWeaver.Graph.GraphModuleTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias BeamWeaver.Checkpoint
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Graph
  alias BeamWeaver.Graph.Channels.BinaryOperatorAggregate
  alias BeamWeaver.Graph.Channels.LastValue
  alias BeamWeaver.Graph.Compiled
  alias BeamWeaver.Stream.Events

  defmodule Greeting do
    use BeamWeaver.Graph

    reducer(:messages, fn existing, update -> existing ++ List.wrap(update) end)
    node(:greet, &__MODULE__.greet/2)
    edge(BeamWeaver.Graph.start(), :greet)
    edge(:greet, BeamWeaver.Graph.end_node())

    def greet(state, runtime) do
      greeting = Map.get(runtime.context || %{}, :greeting, "hello")
      existing = Map.get(state, :messages, [])
      %{messages: existing ++ ["#{greeting}, #{state.name}"], done: true}
    end
  end

  defmodule ReviewPipeline do
    use BeamWeaver.Graph

    node(:draft, fn _state -> %{status: :needs_revision, attempt: 1} end)
    node(:revise, fn _state -> %{revised: true} end)
    node(:final, fn _state -> %{final: true} end)

    edge(BeamWeaver.Graph.start(), :draft)
    edge(:draft, :revise, when: %{status: :needs_revision, attempt: 1..2})
    edge(:draft, :final, default: true)
    edge(:revise, BeamWeaver.Graph.end_node())
    edge(:final, BeamWeaver.Graph.end_node())
  end

  defmodule Workflow do
    use BeamWeaver.Graph

    graph do
      state do
        channel(:summary, merge: :last)
        channel(:framework, merge: :map)
      end

      node(:summary, fn _state -> %{summary: "summary"} end, output: :summary)
      node(:meddic, fn _state -> %{framework: %{meddic: "ok"}} end)
      node(:bant, fn _state -> %{framework: %{bant: "ok"}} end)
      node(:action, fn _state -> %{action: "done"} end)

      edge(start(), :summary)
      edge(:summary, :meddic)
      edge(:summary, :bant)
      join([:meddic, :bant], :action)
      edge(:action, finish())
    end
  end

  defmodule RefundApproval do
    use BeamWeaver.Graph

    alias BeamWeaver.Graph

    name "refund_approval"

    def graph do
      Graph.new()
      |> Graph.add_node(:approve, &approve/1)
      |> Graph.add_node(:refund, &refund/1)
      |> Graph.add_edge(Graph.start(), :approve)
      |> Graph.add_edge(:approve, :refund, when: %{approved: true})
      |> Graph.add_edge(:refund, Graph.end_node())
    end

    def approve(%{order_id: order_id}) do
      %{approved: Graph.interrupt(%{question: "Refund order #{order_id}?"}) == "yes"}
    end

    def refund(%{order_id: order_id}), do: %{reply: "Refund issued for order #{order_id}."}
  end

  defmodule Breakpoints do
    use BeamWeaver.Graph

    alias BeamWeaver.Graph

    interrupts before: Process.get(:graph_module_test_breakpoints, []), after: [:check]
    step_timeout 30_000

    def graph do
      Graph.new()
      |> Graph.add_node(:check, fn _state -> %{checked: true} end)
      |> Graph.add_edge(Graph.start(), :check)
      |> Graph.add_edge(:check, Graph.end_node())
    end
  end

  defmodule SlowGraph do
    use BeamWeaver.Graph

    alias BeamWeaver.Graph

    run_timeout 50

    def graph do
      Graph.new()
      |> Graph.add_node(:wait, fn _state -> Process.sleep(1_000) && %{} end, timeout: 5_000)
      |> Graph.add_edge(Graph.start(), :wait)
      |> Graph.add_edge(:wait, Graph.end_node())
    end
  end

  defmodule Poller do
    use BeamWeaver.Graph

    alias BeamWeaver.Graph

    recursion_limit 3

    def graph do
      Graph.new()
      |> Graph.add_node(:poll, fn %{polls: polls} -> %{polls: polls + 1} end)
      |> Graph.add_edge(Graph.start(), :poll)
      |> Graph.add_edge(:poll, :poll)
    end
  end

  defmodule DeclaredSaver do
    use BeamWeaver.Graph

    alias BeamWeaver.Graph

    checkpointer :persistent_term.get({BeamWeaver.Graph.GraphModuleTest, :saver})

    def graph do
      Graph.new()
      |> Graph.add_node(:count, fn state -> %{count: Map.get(state, :count, 0) + 1} end)
      |> Graph.add_edge(Graph.start(), :count)
      |> Graph.add_edge(:count, Graph.end_node())
    end
  end

  defmodule ForgetfulGraph do
    use BeamWeaver.Graph

    alias BeamWeaver.Graph

    checkpointer BeamWeaver.Graph.GraphModuleTest.new_saver()

    def graph do
      Graph.new()
      |> Graph.add_node(:count, fn state -> %{count: Map.get(state, :count, 0) + 1} end)
      |> Graph.add_edge(Graph.start(), :count)
      |> Graph.add_edge(:count, Graph.end_node())
    end
  end

  defmodule SupportAgent do
    use BeamWeaver.Agent

    model "fake:chat", responses: ["Your order A-1001 shipped on Monday."]
  end

  @thread %{"configurable" => %{"thread_id" => "graph-module"}}

  def new_saver, do: Checkpoint.ETS.new()

  defp single_node_graph(name, node) do
    Graph.new()
    |> Graph.add_node(name, node)
    |> Graph.add_edge(Graph.start(), name)
    |> Graph.add_edge(name, Graph.end_node())
    |> Graph.compile!()
  end

  defp compile_error(source) do
    error = assert_raise CompileError, fn -> Code.compile_string(source, "graph_module_probe.ex") end
    Exception.message(error)
  end

  describe "a graph module" do
    test "runs its declared nodes and edges, with the call's context" do
      assert {:ok, %{messages: ["hi, Ada"], done: true}} = Greeting.invoke(%{name: "Ada"}, context: %{greeting: "hi"})
    end

    test "takes the builder's edge options" do
      assert {:ok, %{revised: true}} = ReviewPipeline.invoke(%{})
    end

    test "declares state channels, nodes, edges and joins in a graph block" do
      graph = Workflow.graph()

      assert %LastValue{} = graph.channels[:summary]
      assert %BinaryOperatorAggregate{} = graph.channels[:framework]
      assert Map.has_key?(graph.nodes, "summary")
      assert "summary" in graph.entry_points
      assert MapSet.member?(graph.finish_points, "action")
      assert [%{upstream: ["meddic", "bant"], target: "action"}] = graph.waiting_edges
    end

    test "pauses, resumes and reads its thread with a checkpointer passed per call" do
      opts = [checkpointer: Checkpoint.ETS.new(), config: @thread]

      assert {:interrupted, %{value: %{question: "Refund order A-1001?"}}} =
               RefundApproval.invoke(%{order_id: "A-1001"}, opts)

      assert {:ok, %{reply: "Refund issued for order A-1001."}} = RefundApproval.resume("yes", opts)
      assert {:ok, %{values: %{reply: "Refund issued for order A-1001."}}} = RefundApproval.get_state(opts)
    end

    test "streams its events" do
      assert {:ok, events} = ReviewPipeline.stream_events(%{}, live: true)

      updates = for %{event: %Events.GraphUpdate{update: update}} <- events, do: Map.keys(update)
      assert updates == [["draft"], ["revise"]]
    end

    test "evaluates its declarations on each call" do
      assert {:ok, %Compiled{interrupt_before: before}} = Breakpoints.compiled_graph()
      assert before == MapSet.new()

      Process.put(:graph_module_test_breakpoints, [:check])

      assert {:ok, compiled} = Breakpoints.compiled_graph()
      assert compiled.interrupt_before == MapSet.new(["check"])
      assert compiled.interrupt_after == MapSet.new(["check"])
      assert compiled.step_timeout == 30_000
    end

    test "is named after its name declaration, or else after the module" do
      assert {:ok, %Compiled{name: "refund_approval"}} = RefundApproval.compiled_graph()
      assert {:ok, %Compiled{name: "BeamWeaver.Graph.GraphModuleTest.ReviewPipeline"}} = ReviewPipeline.compiled_graph()
    end

    test "stops at its declared run_timeout" do
      assert {:error, %Error{type: :run_timeout}} = SlowGraph.invoke(%{})
    end

    test "stops at its declared recursion_limit, unless the call sets one" do
      assert {:error, %Error{type: :recursion_limit, details: %{limit: 3}}} = Poller.invoke(%{polls: 0})

      assert {:error, %Error{type: :recursion_limit, details: %{limit: 5}}} =
               Poller.invoke(%{polls: 0}, recursion_limit: 5)
    end

    test "saves with its declared checkpointer, and a call's checkpointer replaces it" do
      saver = Checkpoint.ETS.new()
      :persistent_term.put({__MODULE__, :saver}, saver)
      on_exit(fn -> :persistent_term.erase({__MODULE__, :saver}) end)

      assert DeclaredSaver.checkpointer() == saver
      assert {:ok, %{count: 1}} = DeclaredSaver.invoke(%{}, config: @thread)
      assert {:ok, %{count: 2}} = DeclaredSaver.invoke(%{}, config: @thread)

      other = Checkpoint.ETS.new()
      assert {:ok, %Compiled{checkpointer: ^other}} = DeclaredSaver.compiled_graph(checkpointer: other)
      assert {:ok, %{count: 1}} = DeclaredSaver.invoke(%{}, checkpointer: other, config: @thread)
    end
  end

  test "a graph module warns once when its checkpointer declaration returns a new saver each time" do
    log = capture_log(fn -> assert {:ok, %{count: 1}} = ForgetfulGraph.invoke(%{}, config: @thread) end)

    assert log =~
             "BeamWeaver.Graph.GraphModuleTest.ForgetfulGraph's `checkpointer` declaration returned a new " <>
               "BeamWeaver.Checkpoint.ETS saver when it was evaluated again"

    refute capture_log(fn -> ForgetfulGraph.invoke(%{}, config: @thread) end) =~ "declaration returned a new"
  end

  describe "the BeamWeaver.Graph behaviour" do
    test "is implemented by graph modules and agent modules" do
      for module <- [Greeting, SupportAgent] do
        assert BeamWeaver.Graph in (module.module_info(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten())
        assert {:ok, %Compiled{}} = module.compiled_graph([])
      end
    end

    test "makes either kind of module a node of another graph" do
      review = single_node_graph(:review, ReviewPipeline)
      assert {:ok, %{revised: true}} = Compiled.invoke(review, %{})
      assert %{"review" => %{module: ReviewPipeline}} = Compiled.get_graph(review).subgraphs

      answer = single_node_graph(:answer, SupportAgent)
      assert {:ok, %{messages: [_question, reply]}} = Compiled.invoke(answer, %{messages: ["Where is my order?"]})
      assert Message.text(reply) == "Your order A-1001 shipped on Monday."
      assert %{"answer" => %{module: SupportAgent}} = Compiled.get_graph(answer).subgraphs
    end
  end

  describe "a graph module doesn't compile" do
    test "with two nodes of the same name" do
      assert compile_error("""
             defmodule BeamWeaver.Graph.GraphModuleTest.Duplicate do
               use BeamWeaver.Graph
               node :same, fn state -> state end
               node :same, fn state -> state end
               edge BeamWeaver.Graph.start(), :same
             end
             """) =~ "duplicate node names: same"
    end

    test "without an edge from the start" do
      assert compile_error("""
             defmodule BeamWeaver.Graph.GraphModuleTest.NoEntry do
               use BeamWeaver.Graph
               node :only, fn state -> state end
             end
             """) =~ "must declare an edge from start()"
    end

    test "without a graph" do
      assert compile_error("""
             defmodule BeamWeaver.Graph.GraphModuleTest.Empty do
               use BeamWeaver.Graph
             end
             """) =~ "declares no graph: define graph/0, or declare its nodes and edges"
    end

    test "with nodes and a graph/0 of its own" do
      assert compile_error("""
             defmodule BeamWeaver.Graph.GraphModuleTest.Both do
               use BeamWeaver.Graph
               node :only, fn state -> state end
               edge BeamWeaver.Graph.start(), :only
               def graph, do: BeamWeaver.Graph.new()
             end
             """) =~ "declares nodes and defines graph/0; keep one of them"
    end

    test "when a declaration creates an in-memory saver" do
      assert compile_error("""
             defmodule BeamWeaver.Graph.GraphModuleTest.InlineSaver do
               use BeamWeaver.Graph
               alias BeamWeaver.Checkpoint
               checkpointer Checkpoint.ETS.new()

               def graph, do: BeamWeaver.Graph.new()
             end
             """) =~ "the `checkpointer` declaration creates a new, empty in-memory saver with `Checkpoint.ETS.new()`"
    end
  end

  test "a state channel merge must be :last, :list, :map or a function" do
    assert_raise ArgumentError, ~s/unknown graph state channel merge "map"/, fn ->
      apply(BeamWeaver.Graph.DSL, :__add_channel__, [Graph.new(), :summary, "map", []])
    end
  end
end
