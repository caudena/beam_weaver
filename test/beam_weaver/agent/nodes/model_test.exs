defmodule BeamWeaver.Agent.Nodes.ModelTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Models
  alias BeamWeaver.OpenAI.ToolCalling
  alias BeamWeaver.Transport.Response

  defmodule LookupOrder do
    use BeamWeaver.Tool

    name "lookup_order"
    description "Look up an order by its id."

    schema do
      field :order_id, :string
    end

    @impl true
    def invoke(_tool, _args, _opts), do: {:ok, "Order A-1001 shipped on Monday."}
  end

  defmodule CaptureTransport do
    @behaviour BeamWeaver.Transport

    @impl true
    def request(request, opts) do
      send(Keyword.fetch!(opts, :parent), {:openai_request, request.json})

      body = %{
        "id" => "resp_1",
        "status" => "completed",
        "output" => [
          %{
            "type" => "message",
            "role" => "assistant",
            "content" => [%{"type" => "output_text", "text" => "Order A-1001 shipped on Monday."}]
          }
        ]
      }

      {:ok, Response.new(status: 200, headers: [], body: BeamWeaver.JSON.encode!(body))}
    end
  end

  defp transport_opts, do: [api_key: "test-key", transport: CaptureTransport, transport_opts: [parent: self()]]

  defp tool_types do
    assert_received {:openai_request, request}
    Enum.map(request["tools"], & &1["type"])
  end

  test "an agent offers provider tools from its model options next to its own tools" do
    web_search = ToolCalling.web_search()

    {:ok, by_string} =
      BeamWeaver.Agent.build(
        model: "openai:gpt-5.4-mini",
        model_opts: [tools: [web_search]] ++ transport_opts(),
        tools: [LookupOrder],
        name: "orders"
      )

    assert {:ok, _result} = BeamWeaver.Agent.invoke(by_string, %{messages: ["Where is order A-1001?"]})
    assert tool_types() == ["web_search_preview", "function"]

    {:ok, by_model} =
      BeamWeaver.Agent.build(
        model: Models.init_chat_model!("openai:gpt-5.4-mini", transport_opts()),
        model_opts: [tools: [web_search]],
        tools: [LookupOrder],
        name: "orders"
      )

    assert {:ok, _result} = BeamWeaver.Agent.invoke(by_model, %{messages: ["Where is order A-1001?"]})
    assert tool_types() == ["web_search_preview", "function"]
  end

  test "an agent keeps the tools bound to its model" do
    model =
      Models.bind_tools(Models.init_chat_model!("openai:gpt-5.4-mini", transport_opts()), [ToolCalling.web_search()])

    {:ok, agent} = BeamWeaver.Agent.build(model: model, tools: [LookupOrder], name: "orders")

    assert {:ok, _result} = BeamWeaver.Agent.invoke(agent, %{messages: ["Where is order A-1001?"]})
    assert tool_types() == ["web_search_preview", "function"]
  end

  test "a model created with stream: true streams inside an agent" do
    model = Models.init_chat_model!("fake:chat", responses: ["Order A-1001 shipped."], stream: true, parent: self())
    {:ok, agent} = BeamWeaver.Agent.build(model: model, name: "orders")

    assert {:ok, _result} = BeamWeaver.Agent.invoke(agent, %{messages: ["Where is order A-1001?"]})
    assert_received {:fake_chat_model_stream, _messages, _opts}
    refute_received {:fake_chat_model_call, _messages, _opts}
  end
end
