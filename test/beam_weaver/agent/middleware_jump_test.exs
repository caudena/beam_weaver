defmodule BeamWeaver.Agent.MiddlewareJumpTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Agent
  alias BeamWeaver.Agent.ExtendedModelResponse
  alias BeamWeaver.Agent.ModelResponse
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Graph.Command
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

  defmodule CloseTicket do
    use BeamWeaver.Tool

    name "close_ticket"
    description "Close a support ticket. The conversation ends with it."

    schema do
      field :ticket_id, :string
    end

    @impl true
    def invoke(_tool, %{"ticket_id" => id}, _opts),
      do: {:ok, BeamWeaver.Agent.jump(:end, %{messages: [Message.tool("Ticket #{id} closed.")]})}
  end

  defmodule DeliveryDay do
    use BeamWeaver.Tool

    name "delivery_day"
    description "Read an order's delivery day."
    return_direct true

    schema do
      field :order_id, :string
    end

    # Its answer is the run's answer, unless the order is late: the model
    # explains that.
    @impl true
    def invoke(_tool, %{"order_id" => "A-1001"}, _opts), do: {:ok, "Thursday."}

    def invoke(_tool, %{"order_id" => id}, _opts),
      do: {:ok, BeamWeaver.Agent.jump(:model, %{messages: [Message.tool("#{id} is late.")]})}
  end

  defmodule NoRefunds do
    use BeamWeaver.Agent.Middleware

    # Ends the run instead of running a refund.
    @impl true
    def wrap_tool_call(_middleware, %{tool_call: %{name: "refund", id: id}}, _handler),
      do: BeamWeaver.Agent.jump(:end, %{messages: [Message.tool("Refunds need a human.", tool_call_id: id)]})

    def wrap_tool_call(_middleware, request, handler), do: handler.(request)
  end

  defmodule Refund do
    use BeamWeaver.Tool

    name "refund"
    description "Refund an order."

    schema do
      field :order_id, :string
    end

    @impl true
    def invoke(_tool, _args, _opts), do: {:ok, "Refunded."}
  end

  defmodule DraftAgain do
    use BeamWeaver.Agent.Middleware

    # Sends a first draft back to the model once.
    @impl true
    def wrap_model_call(_middleware, request, handler) do
      with {:ok, %ModelResponse{messages: [reply]} = response} <- handler.(request) do
        if Message.text(reply) == "draft" do
          %ExtendedModelResponse{
            model_response: response,
            command: BeamWeaver.Agent.jump(:model, %{messages: [Message.user("Please give the final answer.")]})
          }
        else
          {:ok, response}
        end
      end
    end
  end

  defmodule CountReplies do
    use BeamWeaver.Agent.Middleware

    # Counts the replies that reach the after_model hooks.
    @impl true
    def after_model(_middleware, state, _runtime), do: %{replies_seen: Map.get(state, :replies_seen, 0) + 1}
  end

  defmodule NoToolsToday do
    use BeamWeaver.Agent.Middleware

    # Ends the run on a reply that calls tools.
    @impl true
    def wrap_model_call(_middleware, request, handler) do
      with {:ok, %ModelResponse{messages: [%Message{tool_calls: [_ | _]}]} = response} <- handler.(request) do
        %ExtendedModelResponse{model_response: response, command: BeamWeaver.Agent.jump(:end)}
      end
    end
  end

  defmodule CloseTicketAgent do
    use BeamWeaver.Agent

    model "fake:chat", responses: [FakeChatModel.tool_call("close_ticket", %{"ticket_id" => "T-7"}), "Anything else?"]
    tools [BeamWeaver.Agent.MiddlewareJumpTest.CloseTicket]
  end

  defmodule DeliveryDayAgent do
    use BeamWeaver.Agent

    model "fake:chat",
      responses: [FakeChatModel.tool_call("delivery_day", %{"order_id" => "A-1002"}), "Sorry, A-1002 is late."]

    tools [BeamWeaver.Agent.MiddlewareJumpTest.DeliveryDay]
  end

  defmodule NoRefundsAgent do
    use BeamWeaver.Agent

    model "fake:chat", responses: [FakeChatModel.tool_call("refund", %{"order_id" => "A-1001"}), "Refunded."]
    tools [BeamWeaver.Agent.MiddlewareJumpTest.Refund]
    middleware [BeamWeaver.Agent.MiddlewareJumpTest.NoRefunds]
  end

  defmodule CountedDraftAgainAgent do
    use BeamWeaver.Agent

    model "fake:chat", responses: ["draft", "Order A-1001 shipped on Monday."]

    middleware [
      BeamWeaver.Agent.MiddlewareJumpTest.CountReplies,
      BeamWeaver.Agent.MiddlewareJumpTest.DraftAgain
    ]
  end

  defmodule NoToolsTodayAgent do
    use BeamWeaver.Agent

    model "fake:chat", responses: [FakeChatModel.tool_call("wipe_ledger", %{"scope" => "all"}), "Done."]
    tools [BeamWeaver.Agent.MiddlewareJumpTest.WipeLedger]

    middleware [
      BeamWeaver.Agent.MiddlewareJumpTest.CountReplies,
      BeamWeaver.Agent.MiddlewareJumpTest.NoToolsToday
    ]
  end

  defmodule DraftAgainAgent do
    use BeamWeaver.Agent

    model "fake:chat", responses: ["draft", "Order A-1001 shipped on Monday."]
    middleware [BeamWeaver.Agent.MiddlewareJumpTest.DraftAgain]
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

  describe "jump/2" do
    test "a tool that returns a jump to :end ends the run with its update" do
      assert {:ok, result} = CloseTicketAgent.invoke(%{messages: ["Close ticket T-7."]})

      assert Enum.map(result.messages, &{&1.role, Message.text(&1)}) == [
               {:user, "Close ticket T-7."},
               {:assistant, ""},
               {:tool, "Ticket T-7 closed."}
             ]

      refute Map.has_key?(result, :jump_to)
    end

    test "a tool that returns directly sends its result to the model with a jump to :model" do
      assert {:ok, result} = DeliveryDayAgent.invoke(%{messages: ["When does A-1002 arrive?"]})

      assert Enum.map(result.messages, &{&1.role, Message.text(&1)}) == [
               {:user, "When does A-1002 arrive?"},
               {:assistant, ""},
               {:tool, "A-1002 is late."},
               {:assistant, "Sorry, A-1002 is late."}
             ]
    end

    test "a tool wrapper that returns a jump to :end ends the run" do
      assert {:ok, result} = NoRefundsAgent.invoke(%{messages: ["Refund A-1001."]})
      assert Enum.map(result.messages, &{&1.role, Message.text(&1)}) |> List.last() == {:tool, "Refunds need a human."}
    end

    test "a model wrapper's jump to :model gives the model another turn" do
      assert {:ok, result} = DraftAgainAgent.invoke(%{messages: ["Where is order A-1001?"]})

      assert Enum.map(result.messages, &{&1.role, Message.text(&1)}) == [
               {:user, "Where is order A-1001?"},
               {:assistant, "draft"},
               {:user, "Please give the final answer."},
               {:assistant, "Order A-1001 shipped on Monday."}
             ]
    end

    test "a model wrapper's jump to :model skips the after_model hooks" do
      assert {:ok, result} = CountedDraftAgainAgent.invoke(%{messages: ["Where is order A-1001?"]})

      assert Enum.map(result.messages, &{&1.role, Message.text(&1)}) == [
               {:user, "Where is order A-1001?"},
               {:assistant, "draft"},
               {:user, "Please give the final answer."},
               {:assistant, "Order A-1001 shipped on Monday."}
             ]

      # Only the final answer reached them.
      assert result.replies_seen == 1
    end

    test "a model wrapper's jump to :end skips the after_model hooks and the tool calls" do
      assert {:ok, result} = NoToolsTodayAgent.invoke(%{messages: ["Clean up the ledger."]})

      assert Enum.map(result.messages, & &1.role) == [:user, :assistant]
      refute Map.has_key?(result, :replies_seen)
    end

    test "takes :end, :model or :tools" do
      assert %Command{update: %{jump_to: :tools}} = Agent.jump(:tools)
      assert %Command{update: %{jump_to: :end, notes: ["closed"]}} = Agent.jump(:end, %{notes: ["closed"]})

      assert_raise ArgumentError, ~r/:end, :model or :tools/, fn -> Agent.jump(:finish, %{}) end
    end
  end
end
