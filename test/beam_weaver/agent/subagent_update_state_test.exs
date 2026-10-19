defmodule BeamWeaver.Agent.SubagentUpdateStateTest.IssueRefund do
  use BeamWeaver.Tool

  name "issue_refund"
  description "Refund an order to the customer's card."

  schema do
    field :order_id, :string
  end

  @impl true
  def invoke(_tool, %{"order_id" => order_id}, _opts), do: {:ok, "Refunded #{order_id}."}
end

defmodule BeamWeaver.Agent.SubagentUpdateStateTest.ClerkModel do
  # Refunds A-1, then reports the tool result. Each call tells the test process.
  @behaviour BeamWeaver.Core.ChatModel

  alias BeamWeaver.Core.Message

  defstruct []

  def watch, do: :persistent_term.put(__MODULE__, self())

  @impl true
  def invoke(%__MODULE__{}, messages, _opts) do
    send(:persistent_term.get(__MODULE__), :clerk_model_called)

    case Enum.find(Enum.reverse(messages), &(&1.role == :tool)) do
      nil ->
        call = %{id: "refund-A-1", name: "issue_refund", args: %{"order_id" => "A-1"}}
        {:ok, Message.assistant("", tool_calls: [call])}

      tool_message ->
        {:ok, Message.assistant("clerk: " <> Message.text(tool_message))}
    end
  end
end

defmodule BeamWeaver.Agent.SubagentUpdateStateTest.Clerk do
  use BeamWeaver.Agent

  name "clerk"
  description "Refunds the order named in the task."
  model %BeamWeaver.Agent.SubagentUpdateStateTest.ClerkModel{}
  tools [BeamWeaver.Agent.SubagentUpdateStateTest.IssueRefund]
  interrupt_on %{"issue_refund" => true}
end

defmodule BeamWeaver.Agent.SubagentUpdateStateTest.Desk do
  use BeamWeaver.Agent

  alias BeamWeaver.Models.FakeChatModel

  model "fake:chat",
    responses: [
      FakeChatModel.tool_call("task", %{"subagent_type" => "clerk", "description" => "Refund A-1."}),
      "Done."
    ]

  subagents do
    subagent BeamWeaver.Agent.SubagentUpdateStateTest.Clerk
  end
end

defmodule BeamWeaver.Agent.SubagentUpdateStateTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Agent.HITL
  alias BeamWeaver.Agent.SubagentUpdateStateTest.ClerkModel
  alias BeamWeaver.Agent.SubagentUpdateStateTest.Desk
  alias BeamWeaver.Checkpoint
  alias BeamWeaver.Graph.Compiled

  test "update_state while a subagent's review is pending keeps the subagent where it paused" do
    ClerkModel.watch()
    saver = Checkpoint.ETS.new()
    opts = [checkpointer: saver, config: %{"configurable" => %{"thread_id" => "desk-1"}}]

    assert {:interrupted, _interrupt} = Desk.invoke(%{messages: ["Refund A-1, please."]}, opts)
    assert_received :clerk_model_called

    {:ok, graph} = BeamWeaver.Agent.compiled_graph(Desk, checkpointer: saver)
    assert {:ok, _config} = Compiled.update_state(graph, opts[:config], %{todos: []})

    assert {:ok, result} = Desk.resume_review([HITL.decision(:approve)], opts)
    assert result.messages |> List.last() |> BeamWeaver.Core.Message.text() == "Done."

    # The subagent continued after its review: one more model call, not a new run.
    assert_received :clerk_model_called
    refute_received :clerk_model_called
  end
end
