defmodule BeamWeaver.Agent.AnthropicServerToolsTest do
  use ExUnit.Case, async: true

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

  # The first reply searches the web and calls the agent's own tool; the
  # second one answers.
  defmodule Transport do
    @behaviour BeamWeaver.Transport

    @search_use %{
      "type" => "server_tool_use",
      "id" => "srvtoolu_1",
      "name" => "web_search",
      "input" => %{"query" => "carrier delays"}
    }
    @search_result %{
      "type" => "web_search_tool_result",
      "tool_use_id" => "srvtoolu_1",
      "content" => [
        %{"type" => "web_search_result", "url" => "https://x.test", "title" => "X", "encrypted_content" => "abc"}
      ]
    }
    @lookup %{"type" => "tool_use", "id" => "toolu_1", "name" => "lookup_order", "input" => %{"order_id" => "A-1001"}}

    def search_use, do: @search_use
    def search_result, do: @search_result

    @impl true
    def request(request, opts) do
      send(Keyword.fetch!(opts, :parent), {:anthropic_request, request.json})
      first? = length(request.json["messages"]) == 1

      if request.json["stream"] == true do
        {:ok, Response.new(status: 200, headers: [{"content-type", "text/event-stream"}], body: sse(first?))}
      else
        content =
          if first?, do: [@search_use, @search_result, @lookup], else: [%{"type" => "text", "text" => "It shipped."}]

        {:ok,
         Response.new(
           status: 200,
           headers: [{"content-type", "application/json"}],
           body: BeamWeaver.JSON.encode!(message(content))
         )}
      end
    end

    defp message(content) do
      %{
        "id" => "msg_1",
        "type" => "message",
        "role" => "assistant",
        "model" => "claude-haiku-4-5",
        "stop_reason" => "end_turn",
        "usage" => %{"input_tokens" => 10, "output_tokens" => 5},
        "content" => content
      }
    end

    defp sse(true) do
      events([
        start(0, %{@search_use | "input" => %{}}),
        input(0, ~s({"query":)),
        input(0, ~s("carrier delays"})),
        stop(0),
        start(1, @search_result),
        stop(1),
        start(2, %{@lookup | "input" => %{}}),
        input(2, ~s({"order_id":"A-1001"})),
        stop(2)
      ])
    end

    defp sse(false) do
      events([
        start(0, %{"type" => "text", "text" => ""}),
        %{"type" => "content_block_delta", "index" => 0, "delta" => %{"type" => "text_delta", "text" => "It shipped."}},
        stop(0)
      ])
    end

    defp start(index, block), do: %{"type" => "content_block_start", "index" => index, "content_block" => block}
    defp stop(index), do: %{"type" => "content_block_stop", "index" => index}

    defp input(index, json),
      do: %{
        "type" => "content_block_delta",
        "index" => index,
        "delta" => %{"type" => "input_json_delta", "partial_json" => json}
      }

    defp events(events) do
      events = [%{"type" => "message_start", "message" => message([])} | events]

      events =
        events ++
          [%{"type" => "message_delta", "delta" => %{"stop_reason" => "end_turn"}, "usage" => %{"output_tokens" => 5}}]

      Enum.map_join(events, "\n", &"event: #{&1["type"]}\ndata: #{BeamWeaver.JSON.encode!(&1)}\n") <> "\n"
    end
  end

  for stream? <- [false, true] do
    test "an agent with Anthropic web search sends the search back as Anthropic sent it (stream: #{stream?})" do
      {:ok, agent} =
        BeamWeaver.Agent.build(
          name: "orders",
          model: "anthropic:claude-haiku-4-5",
          model_opts: [
            tools: [BeamWeaver.Anthropic.Tools.web_search()],
            api_key: "test-key",
            stream: unquote(stream?),
            transport: Transport,
            transport_opts: [parent: self()]
          ],
          tools: [LookupOrder]
        )

      assert {:ok, _state} = BeamWeaver.Agent.invoke(agent, %{messages: ["Where is order A-1001? Any carrier delays?"]})

      assert_received {:anthropic_request, _first}
      assert_received {:anthropic_request, second}

      assert [_user, %{"role" => "assistant", "content" => content}, _tool_result] = second["messages"]

      assert content == [
               Transport.search_use(),
               Transport.search_result(),
               %{
                 "type" => "tool_use",
                 "id" => "toolu_1",
                 "name" => "lookup_order",
                 "input" => %{"order_id" => "A-1001"}
               }
             ]
    end
  end
end
