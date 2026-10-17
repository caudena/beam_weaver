defmodule BeamWeaver.Agent.StructuredResponseCallTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Models
  alias BeamWeaver.Models.FakeChatModel

  defmodule Answer do
    use BeamWeaver.Schema

    field :status, :string, required: true
  end

  test "the structured answer after a tool loop is asked for in a user turn, not appended to the state" do
    lookup =
      Tool.from_function!(
        name: "lookup_order",
        description: "Look up an order",
        input_schema: %{"type" => "object", "properties" => %{"order_id" => %{"type" => "string"}}},
        handler: fn _args, _opts -> "shipped" end
      )

    model =
      Models.init_chat_model!("fake:chat",
        parent: self(),
        responses: [
          FakeChatModel.tool_call("lookup_order", %{"order_id" => "A-1001"}),
          "It shipped.",
          FakeChatModel.final(%{status: "shipped"})
        ]
      )

    {:ok, agent} = BeamWeaver.Agent.build(model: model, tools: [lookup], response_format: Answer)

    assert {:ok, %{structured_response: %{"status" => "shipped"}, messages: messages}} =
             BeamWeaver.Agent.invoke(agent, %{messages: ["Where is A-1001?"]})

    calls = collect_calls([])
    assert length(calls) == 3
    {final_messages, _opts} = List.last(calls)

    assert %Message{role: :user, content: "Give your final answer now, in the required format."} =
             List.last(final_messages)

    assert Enum.at(final_messages, -2).role == :assistant
    refute Enum.any?(messages, &(&1.content == "Give your final answer now, in the required format."))
  end

  # The thread keeps the last turn's answer in its state; a new turn must get
  # its own instead of ending on that one.
  test "each turn of a checkpointed thread gets its own structured answer" do
    model =
      Models.init_chat_model!("fake:chat",
        responses: [
          FakeChatModel.tool_call("lookup_order", %{"order_id" => "A-1001"}),
          "It shipped.",
          FakeChatModel.final(%{status: "shipped"}),
          "It was delivered.",
          FakeChatModel.final(%{status: "delivered"})
        ]
      )

    {:ok, agent} = BeamWeaver.Agent.build(model: model, tools: [lookup_tool()], response_format: Answer)
    opts = [checkpointer: BeamWeaver.Checkpoint.ETS.new(), config: %{"configurable" => %{"thread_id" => "A-1001"}}]

    assert {:ok, %{structured_response: %{"status" => "shipped"}}} =
             BeamWeaver.Agent.invoke(agent, %{messages: ["Where is A-1001?"]}, opts)

    assert {:ok, %{structured_response: %{"status" => "delivered"}}} =
             BeamWeaver.Agent.invoke(agent, %{messages: ["And now?"]}, opts)
  end

  defp lookup_tool do
    Tool.from_function!(
      name: "lookup_order",
      description: "Look up an order",
      input_schema: %{"type" => "object", "properties" => %{"order_id" => %{"type" => "string"}}},
      handler: fn _args, _opts -> "shipped" end
    )
  end

  defp collect_calls(acc) do
    receive do
      {:fake_chat_model_call, messages, opts} -> collect_calls([{messages, opts} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
