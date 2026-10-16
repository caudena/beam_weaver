defmodule BeamWeaver.Agent.MiddlewareJumpTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.Message
  alias BeamWeaver.Models.FakeChatModel

  defmodule LookupOrder do
    use BeamWeaver.Tool

    name "lookup_order"
    description "Look up the shipping status of an order by its id."

    schema do
      field :order_id, :string
    end

    @impl true
    def invoke(_tool, %{"order_id" => order_id}, _opts), do: {:ok, "#{order_id} shipped on Monday."}
  end

  defmodule AskAgain do
    use BeamWeaver.Agent.Middleware

    # Sends a first draft back to the model once.
    @impl true
    def after_model(_middleware, %{messages: messages}, _runtime) do
      if Message.text(List.last(messages)) == "draft" do
        {:jump, :model, %{messages: [Message.user("Please give the final answer.")]}}
      end
    end
  end

  defmodule LookupFirst do
    use BeamWeaver.Agent.Middleware

    # Looks the order up before the model answers a new question.
    @impl true
    def before_model(_middleware, %{messages: messages}, _runtime) do
      case List.last(messages) do
        %Message{role: :user} ->
          call = %{id: "call-lookup", name: "lookup_order", args: %{"order_id" => "A-1001"}}
          {:jump, :tools, %{messages: [Message.assistant("", tool_calls: [call])]}}

        _other ->
          nil
      end
    end
  end

  defmodule Audit do
    use BeamWeaver.Agent.Middleware

    # Another after_model hook, which runs after AskAgain's and Guard's.
    @impl true
    def after_model(_middleware, _state, _runtime), do: nil
  end

  defmodule WipeLedger do
    use BeamWeaver.Tool

    name "wipe_ledger"
    description "Deletes every entry of the ledger."

    schema do
      field :scope, :string
    end

    @impl true
    def invoke(_tool, _args, _opts), do: {:ok, "Ledger wiped."}
  end

  defmodule Guard do
    use BeamWeaver.Agent.Middleware

    # Ends the run before a wipe_ledger call runs.
    @impl true
    def after_model(_middleware, %{messages: messages}, _runtime) do
      case List.last(messages) do
        %Message{tool_calls: [_ | _] = calls} ->
          if Enum.any?(calls, &(&1.name == "wipe_ledger")), do: {:halt, %{}}

        _other ->
          nil
      end
    end
  end

  defmodule RunToolsNow do
    use BeamWeaver.Agent.Middleware

    # Sends the model's tool calls straight to the tools.
    @impl true
    def after_model(_middleware, %{messages: messages}, _runtime) do
      case List.last(messages) do
        %Message{tool_calls: [_ | _]} -> {:jump, :tools, %{}}
        _other -> nil
      end
    end
  end

  defmodule ReviewedAgent do
    use BeamWeaver.Agent

    model "fake:chat", responses: [FakeChatModel.tool_call("wipe_ledger", %{"scope" => "all"}), "Done."]
    tools [BeamWeaver.Agent.MiddlewareJumpTest.WipeLedger]
    interrupt_on %{"wipe_ledger" => true}
    middleware [BeamWeaver.Agent.MiddlewareJumpTest.RunToolsNow]
  end

  defmodule AskAgainAgent do
    use BeamWeaver.Agent

    model "fake:chat", responses: ["draft", "Order A-1001 shipped on Monday."]
    middleware [BeamWeaver.Agent.MiddlewareJumpTest.AskAgain]
  end

  defmodule AuditedAskAgainAgent do
    use BeamWeaver.Agent

    model "fake:chat", responses: ["draft", "Order A-1001 shipped on Monday."]
    middleware [BeamWeaver.Agent.MiddlewareJumpTest.Audit, BeamWeaver.Agent.MiddlewareJumpTest.AskAgain]
  end

  defmodule GuardedAgent do
    use BeamWeaver.Agent

    model "fake:chat", responses: [FakeChatModel.tool_call("wipe_ledger", %{"scope" => "all"}), "Done."]
    tools [BeamWeaver.Agent.MiddlewareJumpTest.WipeLedger]

    middleware [
      {BeamWeaver.Agent.Middleware.PII, type: :email, apply_to_output: true},
      BeamWeaver.Agent.MiddlewareJumpTest.Guard
    ]
  end

  defmodule LookupFirstAgent do
    use BeamWeaver.Agent

    model "fake:chat", responses: ["Order A-1001 shipped on Monday, so it arrives Thursday."]
    tools [BeamWeaver.Agent.MiddlewareJumpTest.LookupOrder]
    middleware [BeamWeaver.Agent.MiddlewareJumpTest.LookupFirst]
  end

  test "a jump to :model calls the model again, once" do
    assert {:ok, result} = AskAgainAgent.invoke(%{messages: ["Where is order A-1001?"]})

    assert Enum.map(result.messages, &{&1.role, Message.text(&1)}) == [
             {:user, "Where is order A-1001?"},
             {:assistant, "draft"},
             {:user, "Please give the final answer."},
             {:assistant, "Order A-1001 shipped on Monday."}
           ]

    refute Map.has_key?(result, :jump_to)
  end

  test "a jump from an after_model hook holds when another after_model hook runs after it" do
    assert {:ok, result} = AuditedAskAgainAgent.invoke(%{messages: ["Where is order A-1001?"]})

    assert Enum.map(result.messages, &{&1.role, Message.text(&1)}) == [
             {:user, "Where is order A-1001?"},
             {:assistant, "draft"},
             {:user, "Please give the final answer."},
             {:assistant, "Order A-1001 shipped on Monday."}
           ]
  end

  test "a halt from an after_model hook stops the tool calls when another after_model hook runs after it" do
    assert {:ok, result} = GuardedAgent.invoke(%{messages: ["Clean up the ledger."]})

    # The run ends on the model's tool call; wipe_ledger never runs.
    assert Enum.map(result.messages, & &1.role) == [:user, :assistant]
  end

  test "a jump to :tools from an after_model hook still waits for the review of the tool calls" do
    opts = [checkpointer: BeamWeaver.Checkpoint.ETS.new(), config: %{"configurable" => %{"thread_id" => "review"}}]

    assert {:interrupted, interrupt} = ReviewedAgent.invoke(%{messages: ["Clean up the ledger."]}, opts)
    assert Enum.map(interrupt.value.action_requests, & &1.name) == ["wipe_ledger"]
  end

  test "a jump to :tools runs the tools, then the agent goes on as usual" do
    assert {:ok, result} = LookupFirstAgent.invoke(%{messages: ["When does order A-1001 arrive?"]})

    assert Enum.map(result.messages, &{&1.role, Message.text(&1)}) == [
             {:user, "When does order A-1001 arrive?"},
             {:assistant, ""},
             {:tool, "A-1001 shipped on Monday."},
             {:assistant, "Order A-1001 shipped on Monday, so it arrives Thursday."}
           ]
  end
end
