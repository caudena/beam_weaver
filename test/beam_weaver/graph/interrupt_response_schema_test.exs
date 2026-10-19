defmodule BeamWeaver.Graph.InterruptResponseSchemaTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Agent.ToolNode
  alias BeamWeaver.Checkpoint.ETS, as: CheckpointETS
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Graph
  alias BeamWeaver.Graph.Compiled
  alias BeamWeaver.Graph.Send
  alias BeamWeaver.Stream.Envelope
  alias BeamWeaver.Stream.Events

  defmodule Approval do
    use BeamWeaver.Schema

    title "approval"
    field :approved, :boolean
    field :note, :string, required: false
  end

  @choice %{"type" => "string", "enum" => ["refund", "replace"]}

  describe "the interrupt" do
    test "carries the schema of a schema module, and a map as it is given" do
      for {schema, expected} <- [{Approval, Approval.json_schema()}, {@choice, @choice}] do
        graph = ask_graph(fn _state -> %{answer: Graph.interrupt("Approve?", response_schema: schema)} end)
        config = thread()

        assert {:interrupted, %{id: id, response_schema: ^expected, interrupts: [%{response_schema: ^expected}]}} =
                 Compiled.invoke(graph, %{}, config: config)

        assert {:ok, %{interrupts: [%{id: ^id, response_schema: ^expected}]}} = Compiled.get_state(graph, config)
      end
    end

    test "has no schema when none is given" do
      graph = ask_graph(fn _state -> %{answer: Graph.interrupt("Approve?")} end)

      assert {:interrupted, %{response_schema: nil}} = Compiled.invoke(graph, %{}, config: thread())
    end

    test "is streamed with its schema" do
      graph = ask_graph(fn _state -> %{answer: Graph.interrupt("Approve?", response_schema: Approval)} end)
      schema = Approval.json_schema()

      assert {:interrupted, %{events: events}} =
               Compiled.stream_events(graph, %{}, config: thread(), stream_mode: :tasks)

      assert [%{response_schema: ^schema}] =
               for(%Envelope{event: %Events.Task{kind: :interrupt, payload: payload}} <- events, do: payload)
    end

    test "rejects a schema that is neither a map nor a schema module" do
      graph = ask_graph(fn _state -> %{answer: Graph.interrupt("Approve?", response_schema: "approval")} end)

      assert {:error, %Error{type: :node_exception, message: message}} = Compiled.invoke(graph, %{}, config: thread())
      assert message =~ "JSON Schema map or a schema module"
    end
  end

  describe "a resume value" do
    test "that matches the schema is what the interrupt returns, an object with string keys" do
      graph = ask_graph(fn _state -> %{answer: Graph.interrupt("Approve?", response_schema: Approval)} end)
      config = thread()

      assert {:interrupted, _interrupt} = Compiled.invoke(graph, %{}, config: config)

      assert {:ok, %{answer: %{"approved" => true, "note" => "ok"}}} =
               Compiled.resume(graph, %{approved: true, note: "ok"}, config: config)

      graph = ask_graph(fn _state -> %{answer: Graph.interrupt("Refund or replace?", response_schema: @choice)} end)
      config = thread()

      assert {:interrupted, _interrupt} = Compiled.invoke(graph, %{}, config: config)
      assert {:ok, %{answer: "replace"}} = Compiled.resume(graph, "replace", config: config)
    end

    test "that doesn't match fails the run, and the interrupt waits for another answer" do
      runs = :counters.new(1, [])

      graph =
        ask_graph(fn _state ->
          :counters.add(runs, 1, 1)
          %{answer: Graph.interrupt("Approve?", response_schema: Approval)}
        end)

      config = thread()

      assert {:interrupted, %{id: id}} = Compiled.invoke(graph, %{}, config: config)

      assert {:error, %Error{type: :invalid_resume, details: %{interrupt_id: ^id, missing: ["approved"]}}} =
               Compiled.resume(graph, %{note: "looks fine"}, config: config)

      assert {:ok, %{interrupts: [%{id: ^id}], next: ["ask"]}} = Compiled.get_state(graph, config)

      assert {:error, %Error{type: :invalid_resume, details: %{interrupt_id: ^id, key: "approved"}}} =
               Compiled.resume(graph, %{id => %{approved: "yes"}}, config: config)

      assert {:ok, %{answer: %{"approved" => true}}} = Compiled.resume(graph, %{approved: true}, config: config)
      assert :counters.get(runs, 1) == 4
    end

    test "that doesn't match a map schema fails the same way" do
      graph = ask_graph(fn _state -> %{answer: Graph.interrupt("Refund or replace?", response_schema: @choice)} end)
      config = thread()

      assert {:interrupted, _interrupt} = Compiled.invoke(graph, %{}, config: config)
      assert {:error, %Error{type: :invalid_resume}} = Compiled.resume(graph, "both", config: config)
      assert {:ok, %{answer: "refund"}} = Compiled.resume(graph, "refund", config: config)
    end

    test "that doesn't match is not retried, whatever the policy, and doesn't reach the node's error handler" do
      for retry_on <- [:error, :all] do
        runs = :counters.new(1, [])

        graph =
          Graph.new()
          |> Graph.add_node(
            :ask,
            fn _state ->
              :counters.add(runs, 1, 1)
              %{answer: Graph.interrupt("Approve?", response_schema: Approval)}
            end,
            retry: [max_attempts: 3, initial_delay: 0, retry_on: retry_on],
            error_handler: fn _error -> %{answer: :fallback} end
          )
          |> Graph.add_edge(Graph.start(), :ask)
          |> Graph.add_edge(:ask, Graph.end_node())
          |> Graph.compile!(checkpointer: CheckpointETS.new())

        config = thread()

        assert {:interrupted, _interrupt} = Compiled.invoke(graph, %{}, config: config)

        for answer <- [%{approved: "yes"}, ~D[2026-10-17], Graph.null_resume()] do
          assert {:error, %Error{type: :invalid_resume}} = Compiled.resume(graph, answer, config: config)
        end

        assert :counters.get(runs, 1) == 4
      end
    end

    test "is checked against a schema's enum also when the schema has no type" do
      graph =
        ask_graph(fn _state ->
          %{answer: Graph.interrupt("Which plan?", response_schema: %{"enum" => [%{"plan" => "basic"}]})}
        end)

      config = thread()

      assert {:interrupted, _interrupt} = Compiled.invoke(graph, %{}, config: config)
      assert {:error, %Error{type: :invalid_resume}} = Compiled.resume(graph, %{"plan" => "pro"}, config: config)
      assert {:ok, %{answer: %{"plan" => "basic"}}} = Compiled.resume(graph, %{"plan" => "basic"}, config: config)
    end

    test "that doesn't match fails a tool's call instead of answering it with a tool error" do
      refund =
        Tool.from_function!(
          name: "refund",
          description: "Refund an order",
          input_schema: %{"type" => "object", "properties" => %{"order_id" => %{"type" => "string"}}},
          handler: fn %{"order_id" => order_id}, _opts ->
            %{"approved" => approved} = Graph.interrupt("Refund #{order_id}?", response_schema: Approval)
            if approved, do: "refunded #{order_id}", else: "kept #{order_id}"
          end
        )

      call = %{
        __type: :tool_call_with_context,
        tool_call: %{id: "call-1", name: "refund", args: %{"order_id" => "A-1"}}
      }

      graph =
        Graph.new(state_schema: Graph.Messages.state_schema())
        |> Graph.add_node(:plan, fn _state -> [%Send{node: :tools, update: call}] end)
        |> Graph.add_node(:tools, ToolNode.new([refund]))
        |> Graph.add_edge(Graph.start(), :plan)
        |> Graph.add_edge(:tools, Graph.end_node())
        |> Graph.compile!(checkpointer: CheckpointETS.new())

      config = thread()

      assert {:interrupted, %{value: "Refund A-1?"}} = Compiled.invoke(graph, %{messages: []}, config: config)
      assert {:error, %Error{type: :invalid_resume}} = Compiled.resume(graph, %{note: "sure"}, config: config)

      assert {:ok, %{messages: [%{content: "refunded A-1"}]}} =
               Compiled.resume(graph, %{approved: true}, config: config)
    end
  end

  describe "in a subgraph" do
    test "the parent's interrupt carries the schema, and an answer that doesn't match waits for another" do
      child =
        Graph.new()
        |> Graph.add_node(:ask, fn _state -> %{answer: Graph.interrupt("Approve?", response_schema: Approval)} end)
        |> Graph.add_edge(Graph.start(), :ask)
        |> Graph.add_edge(:ask, Graph.end_node())
        |> Graph.compile!(checkpointer: true)

      graph =
        Graph.new()
        |> Graph.add_node(:review, child)
        |> Graph.add_edge(Graph.start(), :review)
        |> Graph.add_edge(:review, Graph.end_node())
        |> Graph.compile!(checkpointer: CheckpointETS.new())

      config = thread()
      schema = Approval.json_schema()

      assert {:interrupted, %{id: id, response_schema: ^schema}} = Compiled.invoke(graph, %{}, config: config)
      assert {:error, %Error{type: :invalid_resume}} = Compiled.resume(graph, %{approved: "yes"}, config: config)
      assert {:ok, %{interrupts: [%{id: ^id, response_schema: ^schema}]}} = Compiled.get_state(graph, config)
      assert {:ok, %{answer: %{"approved" => false}}} = Compiled.resume(graph, %{approved: false}, config: config)
    end
  end

  defp ask_graph(ask) do
    Graph.new()
    |> Graph.add_node(:ask, ask)
    |> Graph.add_edge(Graph.start(), :ask)
    |> Graph.add_edge(:ask, Graph.end_node())
    |> Graph.compile!(checkpointer: CheckpointETS.new())
  end

  defp thread, do: %{"configurable" => %{"thread_id" => "thread-#{System.unique_integer([:positive])}"}}
end
