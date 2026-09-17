defmodule BeamWeaver.Agent.ModuleToolInputTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Agent
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Messages.ToolCall

  defmodule SearchOrders do
    use BeamWeaver.Tool

    name("search_orders")
    description("Search orders by status.")

    injected(:context, :context, type: :object)

    schema do
      field(:status, :string)
      field(:limit, :integer, required: false, default: 10)
    end

    @impl true
    def invoke(_tool, input, _opts) do
      {:ok, "Found #{input["limit"]} #{input["status"]} orders for #{input.context.user_id}."}
    end
  end

  defmodule CallingModel do
    @moduledoc false
    # Calls search_orders with the arguments of the test, then repeats the tool result.
    @behaviour BeamWeaver.Core.ChatModel

    defstruct [:args]

    @impl true
    def invoke(%__MODULE__{args: args}, messages, _opts) do
      case List.last(messages) do
        %Message{role: :tool} = result ->
          {:ok, Message.assistant(Message.text(result))}

        _user ->
          call = %ToolCall{id: "call-1", call_id: "call-1", name: "search_orders", args: args}
          {:ok, Message.assistant("", tool_calls: [call])}
      end
    end
  end

  test "a module tool called by a model reads its fields, defaults included, under string keys" do
    assert reply(%{"status" => "shipped"}) == "Found 10 shipped orders for u1."
    assert reply(%{"status" => "shipped", "limit" => 3}) == "Found 3 shipped orders for u1."
  end

  defp reply(args) do
    {:ok, agent} = Agent.build(model: %CallingModel{args: args}, tools: [SearchOrders])

    assert {:ok, %{messages: messages}} =
             Agent.invoke(agent, %{messages: [Message.user("How many?")]}, context: %{user_id: "u1"})

    messages |> List.last() |> Message.text()
  end
end
