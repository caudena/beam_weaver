defmodule BeamWeaver.Agent.ContinueThreadTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Checkpoint.ETS, as: CheckpointETS
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Graph.Command
  alias BeamWeaver.Models.FakeChatModel
  alias BeamWeaver.Stream.Envelope
  alias BeamWeaver.Stream.Events

  defmodule Tools do
    # `lookup_order` reports that it started and hangs when the call's
    # context asks for it, so a test can stop the run during the tool call.
    def lookup_order do
      Tool.from_function!(
        name: "lookup_order",
        description: "Look up an order.",
        input_schema: %{
          "type" => "object",
          "required" => ["order_id"],
          "properties" => %{"order_id" => %{"type" => "string"}}
        },
        injected: %{"context" => :context},
        handler: fn %{"order_id" => order_id} = args, _opts ->
          if pid = (args["context"] || %{})[:stop_in_tool] do
            send(pid, :tool_started)
            Process.sleep(:infinity)
          end

          "Order #{order_id} shipped on Monday."
        end
      )
    end

    def cancel_order do
      Tool.from_function!(
        name: "cancel_order",
        description: "Cancel an order.",
        input_schema: %{"type" => "object", "properties" => %{"order_id" => %{"type" => "string"}}},
        handler: fn %{"order_id" => order_id}, _opts -> "Order #{order_id} cancelled." end
      )
    end
  end

  defmodule SupportAgent do
    use BeamWeaver.Agent

    model "fake:chat",
      responses: [
        FakeChatModel.tool_call("lookup_order", %{"order_id" => "A-1"}),
        "It shipped on Monday."
      ]

    tools [BeamWeaver.Agent.ContinueThreadTest.Tools.lookup_order()]
  end

  defmodule BeforeToolsAgent do
    use BeamWeaver.Agent

    model "fake:chat",
      responses: [
        FakeChatModel.tool_call("lookup_order", %{"order_id" => "A-1"}),
        "It shipped on Monday."
      ]

    tools [BeamWeaver.Agent.ContinueThreadTest.Tools.lookup_order()]
    interrupt_before [:tools]
  end

  defmodule AfterModelAgent do
    use BeamWeaver.Agent

    model "fake:chat",
      responses: [
        FakeChatModel.tool_call("lookup_order", %{"order_id" => "A-1"}),
        "It shipped on Monday."
      ]

    tools [BeamWeaver.Agent.ContinueThreadTest.Tools.lookup_order()]
    interrupt_after ["model"]
  end

  defmodule NoCancelAgent do
    use BeamWeaver.Agent

    model "fake:chat",
      responses: [
        FakeChatModel.tool_calls([
          {"lookup_order", %{"order_id" => "A-1"}},
          {"cancel_order", %{"order_id" => "A-1"}}
        ]),
        "It shipped on Monday."
      ]

    tools [
      BeamWeaver.Agent.ContinueThreadTest.Tools.lookup_order(),
      BeamWeaver.Agent.ContinueThreadTest.Tools.cancel_order()
    ]

    exclude_tools ["cancel_order"]
  end

  defmodule SchemaAgent do
    use BeamWeaver.Agent

    model "fake:chat",
      responses: [
        FakeChatModel.tool_call("lookup_order", %{"order_id" => "A-1"}),
        "It shipped on Monday."
      ]

    tools [BeamWeaver.Agent.ContinueThreadTest.Tools.lookup_order()]
    input_schema %{messages: BeamWeaver.Agent.Schema.field(:messages, :list, required: true)}
    interrupt_before [:tools]
  end

  test "the input schema checks new input, not a command or an empty input that continues the thread" do
    assert {:error, %BeamWeaver.Core.Error{type: :invalid_agent_input}} = SchemaAgent.invoke(%{order: "A-1"})

    opts = [checkpointer: CheckpointETS.new(), config: thread("agent-schema-command")]
    assert {:interrupted, _interrupt} = SchemaAgent.invoke(%{messages: ["Where is A-1?"]}, opts)
    assert {:ok, state} = SchemaAgent.invoke(%Command{resume: :go}, opts)
    assert Message.text(List.last(state.messages)) == "It shipped on Monday."

    opts = [checkpointer: CheckpointETS.new(), config: thread("agent-schema-empty")]
    assert {:interrupted, _interrupt} = SchemaAgent.invoke(%{messages: ["Where is A-1?"]}, opts)
    assert {:ok, events} = SchemaAgent.stream_events(%{}, opts)
    assert [_ | _] = Enum.to_list(events)
    assert {:ok, %{next: []}} = SchemaAgent.get_state(opts)
  end

  test "invoke with no new input continues a run that stopped during a tool call" do
    opts = [checkpointer: CheckpointETS.new(), config: thread("agent-crash-invoke")]

    stop_in_tool(fn context ->
      SupportAgent.invoke(%{messages: ["Where is A-1?"]}, [context: context] ++ opts)
    end)

    assert {:ok, %{next: ["tools"]}} = SupportAgent.get_state(opts)

    assert {:ok, state} = SupportAgent.invoke(%{}, opts)
    assert Enum.map(state.messages, & &1.role) == [:user, :assistant, :tool, :assistant]
    assert Message.text(List.last(state.messages)) == "It shipped on Monday."
  end

  test "a run continued after a crash refuses a tool that exclude_tools hides, as the run did" do
    opts = [checkpointer: CheckpointETS.new(), config: thread("agent-crash-excluded")]

    stop_in_tool(fn context ->
      NoCancelAgent.invoke(%{messages: ["Where is A-1?"]}, [context: context] ++ opts)
    end)

    assert {:ok, state} = NoCancelAgent.invoke(%{}, opts)

    assert ["Order A-1 shipped on Monday.", "Tool error: tool is not registered" <> _] =
             for(%Message{role: :tool} = message <- state.messages, do: Message.text(message))
  end

  test "resume continues a run that stopped during a tool call" do
    opts = [checkpointer: CheckpointETS.new(), config: thread("agent-crash-resume")]

    stop_in_tool(fn context ->
      SupportAgent.invoke(%{messages: ["Where is A-1?"]}, [context: context] ++ opts)
    end)

    assert {:ok, state} = SupportAgent.resume(nil, opts)
    assert Message.text(List.last(state.messages)) == "It shipped on Monday."
  end

  test "resume continues past interrupt_before" do
    opts = [checkpointer: CheckpointETS.new(), config: thread("agent-before-tools")]

    assert {:interrupted, %{timing: :before, nodes: ["tools"]}} =
             BeforeToolsAgent.invoke(%{messages: ["Where is A-1?"]}, opts)

    assert {:ok, state} = BeforeToolsAgent.resume(nil, opts)
    assert Enum.map(state.messages, & &1.role) == [:user, :assistant, :tool, :assistant]
  end

  test "resume continues past interrupt_after, which pauses after each model call" do
    opts = [checkpointer: CheckpointETS.new(), config: thread("agent-after-model")]

    assert {:interrupted, %{timing: :after, nodes: ["model"]}} =
             AfterModelAgent.invoke(%{messages: ["Where is A-1?"]}, opts)

    assert {:interrupted, %{timing: :after, nodes: ["model"]}} = AfterModelAgent.resume(nil, opts)

    assert {:ok, state} = AfterModelAgent.resume(nil, opts)
    assert Message.text(List.last(state.messages)) == "It shipped on Monday."
  end

  test "a command input continues the thread" do
    opts = [checkpointer: CheckpointETS.new(), config: thread("agent-command")]

    assert {:interrupted, _interrupt} = BeforeToolsAgent.invoke(%{messages: ["Where is A-1?"]}, opts)
    assert {:ok, state} = BeforeToolsAgent.invoke(%Command{resume: :go}, opts)
    assert Message.text(List.last(state.messages)) == "It shipped on Monday."
  end

  test "stream_events with no new input streams the rest of the run" do
    opts = [checkpointer: CheckpointETS.new(), config: thread("agent-stream")]

    assert {:interrupted, _interrupt} = BeforeToolsAgent.invoke(%{messages: ["Where is A-1?"]}, opts)
    assert {:ok, events} = BeforeToolsAgent.stream_events(%{}, opts)

    assert ["lookup_order"] ==
             for(%Envelope{event: %Events.ToolStart{tool_name: name}} <- events, do: name)

    assert {:ok, %{next: [], values: %{messages: messages}}} = BeforeToolsAgent.get_state(opts)
    assert Message.text(List.last(messages)) == "It shipped on Monday."
  end

  # Runs the agent in another process and kills that process during the tool
  # call, the way a crash or a deploy stops a run.
  defp stop_in_tool(run) do
    test = self()
    {pid, ref} = spawn_monitor(fn -> run.(%{stop_in_tool: test}) end)
    # However long the run takes to get there, unless it ends first.
    receive do
      :tool_started -> :ok
      {:DOWN, ^ref, :process, ^pid, reason} -> flunk("the run ended before tool started: #{inspect(reason)}")
    end

    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^ref, :process, ^pid, reason} -> assert reason == :killed
    end
  end

  defp thread(id), do: %{"configurable" => %{"thread_id" => id}}
end
