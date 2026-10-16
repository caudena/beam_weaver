defmodule BeamWeaver.Moonshot.StructuredOutputTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Agent.StructuredOutput
  alias BeamWeaver.Core.ChatModel
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Models
  alias BeamWeaver.Transport.Response

  defmodule LookupOrder do
    use BeamWeaver.Tool

    name "lookup_order"
    description "Look up the shipping status of an order by its id."

    schema do
      field :order_id, :string
    end

    @impl true
    def invoke(_tool, %{"order_id" => order_id}, _opts),
      do: {:ok, "Order #{order_id} shipped on Monday with DHL and arrives in 2 days."}
  end

  defmodule OrderStatus do
    use BeamWeaver.Schema

    title "order_status"
    strict true

    field :order_id, :string
    field :carrier, :string
    field :days_until_delivery, :integer
  end

  # Answers each request with the next scripted Chat Completions message and
  # sends the request body to the test.
  defmodule ScriptedTransport do
    @behaviour BeamWeaver.Transport

    @impl true
    def request(request, opts) do
      send(Keyword.fetch!(opts, :parent), {:moonshot_request, request.json})
      message = Agent.get_and_update(Keyword.fetch!(opts, :script), fn [next | rest] -> {next, rest} end)

      body = %{
        "id" => "chatcmpl-#{System.unique_integer([:positive])}",
        "model" => request.json["model"],
        "choices" => [%{"index" => 0, "message" => message, "finish_reason" => "stop"}],
        "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 5, "total_tokens" => 15}
      }

      {:ok, Response.new(status: 200, headers: [], body: BeamWeaver.JSON.encode!(body))}
    end
  end

  @lookup_call %{
    "role" => "assistant",
    "content" => "",
    "reasoning_content" => "Look the order up.",
    "tool_calls" => [
      %{
        "id" => "lookup_order_0",
        "type" => "function",
        "function" => %{"name" => "lookup_order", "arguments" => ~s({"order_id": "A-1001"})}
      }
    ]
  }

  @status %{"order_id" => "A-1001", "carrier" => "DHL", "days_until_delivery" => 2}

  defp kimi(script) do
    {:ok, script} = Agent.start_link(fn -> script end)

    Models.init_chat_model!("moonshot:kimi-k2.6",
      api_key: "test-key",
      transport: ScriptedTransport,
      transport_opts: [parent: self(), script: script]
    )
  end

  test "an agent with tools gets a structured response from Kimi K2.6" do
    model =
      kimi([
        @lookup_call,
        %{"role" => "assistant", "content" => "Order A-1001 ships with DHL and arrives in 2 days."},
        %{"role" => "assistant", "content" => BeamWeaver.JSON.encode!(@status)}
      ])

    {:ok, agent} =
      BeamWeaver.Agent.build(model: model, tools: [LookupOrder], response_format: OrderStatus, name: "orders")

    assert {:ok, %{structured_response: @status}} =
             BeamWeaver.Agent.invoke(agent, %{messages: ["Where is my order A-1001?"]})

    assert_received {:moonshot_request, %{"tools" => [_lookup]} = first}
    refute Map.has_key?(first, "response_format")
    assert_received {:moonshot_request, _second}
    assert_received {:moonshot_request, final}

    assert final["response_format"] == %{"type" => "json_object"}
    refute Map.has_key?(final, "tools")

    assert Enum.any?(
             final["messages"],
             &(&1["role"] == "system" and &1["content"] =~ "Required keys: order_id, carrier, days_until_delivery")
           )
  end

  test "the tool strategy on Kimi K2.6 offers the schema tool without forcing a tool choice" do
    model =
      kimi([
        %{
          "role" => "assistant",
          "content" => "",
          "tool_calls" => [
            %{
              "id" => "order_status_0",
              "type" => "function",
              "function" => %{"name" => "OrderStatus", "arguments" => BeamWeaver.JSON.encode!(@status)}
            }
          ]
        }
      ])

    {:ok, agent} =
      BeamWeaver.Agent.build(model: model, response_format: StructuredOutput.tool(OrderStatus), name: "orders")

    assert {:ok, %{structured_response: @status}} =
             BeamWeaver.Agent.invoke(agent, %{messages: ["Where is my order A-1001?"]})

    assert_received {:moonshot_request, request}
    assert [%{"function" => %{"name" => "OrderStatus"}}] = request["tools"]
    refute Map.has_key?(request, "tool_choice")
  end

  test "Kimi K2.6 parses a JSON-mode reply against the schema on a direct call" do
    model = kimi([%{"role" => "assistant", "content" => ~s({"answer": "pong"})}])
    schema = %{type: :object, properties: %{answer: %{type: :string}}, required: [:answer]}

    assert {:ok, reply} =
             ChatModel.invoke(model, [Message.user("ping")], response_format: %{name: "Answer", schema: schema})

    assert reply.metadata.parsed == %{"answer" => "pong"}
    assert_received {:moonshot_request, %{"response_format" => %{"type" => "json_object"}}}
  end

  test "a forced tool choice is taken only where Kimi accepts it" do
    model = Models.init_chat_model!("moonshot:kimi-k2.6")

    refute BeamWeaver.Moonshot.ChatModel.forced_tool_choice?(model, [])
    assert BeamWeaver.Moonshot.ChatModel.forced_tool_choice?(model, thinking: %{type: :disabled})
    assert BeamWeaver.Moonshot.ChatModel.forced_tool_choice?(Models.init_chat_model!("moonshot:kimi-k3"), [])
    refute BeamWeaver.Moonshot.ChatModel.forced_tool_choice?(Models.init_chat_model!("moonshot:kimi-k2.7-code"), [])
  end
end
