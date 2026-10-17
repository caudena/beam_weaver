defmodule BeamWeaver.Graph.SubgraphInterruptsTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Agent, as: BWAgent
  alias BeamWeaver.Agent.Middleware.HumanInTheLoop
  alias BeamWeaver.Checkpoint
  alias BeamWeaver.Checkpoint.ETS, as: CheckpointETS
  alias BeamWeaver.Core.{ChatModel, Error, Message, Tool}
  alias BeamWeaver.Graph
  alias BeamWeaver.Graph.Channels.BinaryOperatorAggregate
  alias BeamWeaver.Graph.Compiled

  defmodule TwoCallsModel do
    @behaviour ChatModel

    defstruct []

    @impl true
    def invoke(_model, messages, _opts) do
      case Enum.filter(messages, &(&1.role == :tool)) do
        [] ->
          {:ok,
           Message.assistant("",
             tool_calls: [
               %{id: "call-email", name: "send_email", args: %{"to" => "alice@example.com"}},
               %{id: "call-delete", name: "delete_file", args: %{"path" => "report.txt"}}
             ]
           )}

        results ->
          {:ok, Message.assistant("Done with #{length(results)} calls.")}
      end
    end
  end

  defp schema, do: %{log: Graph.channel({BinaryOperatorAggregate, &(&1 ++ &2)}, initial: [])}

  defp counter do
    {:ok, pid} = Agent.start_link(fn -> %{} end)
    pid
  end

  defp bump(pid, key), do: Agent.update(pid, &Map.update(&1, key, 1, fn n -> n + 1 end))
  defp calls(pid), do: Agent.get(pid, & &1)

  # A child whose nodes `a` and `b` start together and both ask.
  defp child(calls) do
    Graph.new(state_schema: schema(), name: "child")
    |> Graph.add_node(:a, fn _state ->
      bump(calls, :a)
      %{log: ["a:" <> Graph.interrupt("A")]}
    end)
    |> Graph.add_node(:b, fn _state ->
      bump(calls, :b)
      %{log: ["b:" <> Graph.interrupt("B")]}
    end)
    |> Graph.add_edge(Graph.start(), :a)
    |> Graph.add_edge(Graph.start(), :b)
    |> Graph.compile!(name: "child")
  end

  defp parent(node) do
    Graph.new(state_schema: schema(), name: "parent")
    |> Graph.add_node(:child, node)
    |> Graph.add_edge(Graph.start(), :child)
    |> Graph.compile!(checkpointer: CheckpointETS.new(), name: "parent")
  end

  defp values(interrupts), do: interrupts |> Enum.map(& &1.value) |> Enum.sort()
  defp by_value(interrupts, value), do: Enum.find(interrupts, &(&1.value == value))

  describe "a subgraph that pauses in two parallel nodes" do
    test "lists both pauses, and one map answers both" do
      graph = parent(child(counter()))
      config = thread("subgraph-both")

      assert {:interrupted, interrupt} = Compiled.invoke(graph, %{log: []}, config: config)
      assert values(interrupt.interrupts) == ["A", "B"]

      assert {:ok, snapshot} = Compiled.get_state(graph, config)
      assert values(snapshot.interrupts) == ["A", "B"]

      assert Enum.map(snapshot.interrupts, & &1.id) |> Enum.sort() ==
               Enum.map(interrupt.interrupts, & &1.id) |> Enum.sort()

      assert {:error, %Error{type: :invalid_resume}} = Compiled.resume(graph, "yes", config: config)

      answers = Map.new(interrupt.interrupts, &{&1.id, String.downcase(&1.value)})
      assert {:ok, %{log: log}} = Compiled.resume(graph, answers, config: config)
      assert Enum.sort(log) == ["a:a", "b:b"]
    end

    test "answers one pause at a time without running the finished node again" do
      calls = counter()
      graph = parent(child(calls))
      config = thread("subgraph-one-at-a-time")

      assert {:interrupted, interrupt} = Compiled.invoke(graph, %{log: []}, config: config)

      assert {:interrupted, second} =
               Compiled.resume(graph, %{by_value(interrupt.interrupts, "A").id => "x"}, config: config)

      assert values(second.interrupts) == ["B"]
      assert {:ok, snapshot} = Compiled.get_state(graph, config)
      assert values(snapshot.interrupts) == ["B"]
      assert snapshot.next == ["child"]

      assert {:ok, %{log: log}} =
               Compiled.resume(graph, %{by_value(snapshot.interrupts, "B").id => "y"}, config: config)

      assert Enum.sort(log) == ["a:x", "b:y"]
      assert calls(calls) == %{a: 2, b: 3}
    end

    test "two levels down, the same map answers both" do
      middle =
        Graph.new(state_schema: schema(), name: "middle")
        |> Graph.add_node(:inner, child(counter()))
        |> Graph.add_edge(Graph.start(), :inner)
        |> Graph.compile!(name: "middle")

      graph = parent(middle)
      config = thread("subgraph-nested")

      assert {:interrupted, interrupt} = Compiled.invoke(graph, %{log: []}, config: config)
      assert values(interrupt.interrupts) == ["A", "B"]
      assert {:ok, %{interrupts: pending}} = Compiled.get_state(graph, config)
      assert values(pending) == ["A", "B"]

      answers = Map.new(interrupt.interrupts, &{&1.id, String.downcase(&1.value)})
      assert {:ok, %{log: log}} = Compiled.resume(graph, answers, config: config)
      assert Enum.sort(log) == ["a:a", "b:b"]
    end

    test "two levels down, a pause saved with the inner subgraph's pause nested still lists and answers both" do
      saver = CheckpointETS.new()

      middle =
        Graph.new(state_schema: schema(), name: "middle")
        |> Graph.add_node(:inner, child(counter()))
        |> Graph.add_edge(Graph.start(), :inner)
        |> Graph.compile!(name: "middle")

      graph =
        Graph.new(state_schema: schema(), name: "parent")
        |> Graph.add_node(:child, middle)
        |> Graph.add_edge(Graph.start(), :child)
        |> Graph.compile!(checkpointer: saver, name: "parent")

      config = thread("subgraph-nested-saved")
      assert {:interrupted, _interrupt} = Compiled.invoke(graph, %{log: []}, config: config)

      # Saved as earlier releases did: the middle graph's pause lists the
      # inner graph's pause, which lists the two pauses.
      tuple = Checkpoint.get_tuple(saver, config)
      [%{task_id: task_id, path: path, value: saved}] = tuple.pending_write_records
      earlier = Map.put(saved, :interrupts, [saved])
      assert :ok = Checkpoint.put_writes(saver, tuple.config, [{"__interrupt__", earlier}], task_id, path)

      assert {:ok, %{interrupts: pending}} = Compiled.get_state(graph, config)
      assert values(pending) == ["A", "B"]

      answers = Map.new(pending, &{&1.id, String.downcase(&1.value)})
      assert {:ok, %{log: log}} = Compiled.resume(graph, answers, config: config)
      assert Enum.sort(log) == ["a:a", "b:b"]
    end
  end

  test "an agent that reviews each call on its own, run as a node, resumes with one map" do
    tool = fn name, field ->
      Tool.from_function!(
        name: name,
        description: "Run #{name}.",
        input_schema: %{"type" => "object", "required" => [field], "properties" => %{field => %{"type" => "string"}}},
        handler: fn _args, _opts -> "#{name} done" end
      )
    end

    {:ok, agent} =
      BWAgent.build(
        model: %TwoCallsModel{},
        tools: [tool.("send_email", "to"), tool.("delete_file", "path")],
        middleware: [
          HumanInTheLoop.new(interrupt_on: %{"send_email" => true, "delete_file" => true}, interrupt_mode: :per_call)
        ]
      )

    graph =
      Graph.new(name: "desk", state_schema: BeamWeaver.Graph.Messages.state_schema())
      |> Graph.add_node(:support, agent.compiled)
      |> Graph.add_edge(Graph.start(), :support)
      |> Graph.add_edge(:support, Graph.end_node())
      |> Graph.compile!(checkpointer: CheckpointETS.new(), name: "desk")

    config = thread("agent-per-call")

    assert {:interrupted, interrupt} = Compiled.invoke(graph, %{messages: [Message.user("Go.")]}, config: config)
    assert interrupt.interrupts |> Enum.map(& &1.value.name) |> Enum.sort() == ["delete_file", "send_email"]

    answers = Map.new(interrupt.interrupts, &{&1.id, %{type: "approve"}})
    assert {:ok, %{messages: messages}} = Compiled.resume(graph, answers, config: config)

    assert messages |> Enum.filter(&(&1.role == :tool)) |> Enum.map(&Message.text/1) |> Enum.sort() ==
             ["delete_file done", "send_email done"]

    assert messages |> List.last() |> Message.text() == "Done with 2 calls."
  end

  defp thread(id), do: %{"configurable" => %{"thread_id" => id}}
end
