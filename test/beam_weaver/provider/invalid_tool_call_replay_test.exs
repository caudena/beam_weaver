defmodule BeamWeaver.Provider.InvalidToolCallReplayTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Messages.InvalidToolCall
  alias BeamWeaver.Models

  # The agent answers a tool call whose arguments came back malformed with an
  # error tool message. Every provider must send the call along with it, or
  # it refuses a result that answers no call.
  @args ~s({"order_id": "A-2)
  @invalid %InvalidToolCall{id: "call_bad", name: "lookup_order", args: @args, error: "invalid JSON"}

  test "Anthropic sends it as a tool_use block" do
    %{"messages" => messages} = body("anthropic:claude-haiku-4-5")

    assert [%{"type" => "tool_use", "id" => id, "name" => "lookup_order", "input" => %{}}] =
             blocks(messages, "assistant")

    # Anthropic takes its own id format; the call and its result agree on it.
    assert Enum.any?(blocks(messages, "user"), &match?(%{"type" => "tool_result", "tool_use_id" => ^id}, &1))
  end

  test "Gemini sends it as a function call" do
    %{"contents" => contents} = body("google:gemini-3.5-flash")

    assert [%{"functionCall" => %{"name" => "lookup_order", "args" => %{}}}] =
             for(%{"role" => "model", "parts" => parts} <- contents, part <- parts, do: part)
  end

  for id <- ["moonshot:kimi-k2.6", "zai:glm-5.2"] do
    test "#{id} sends it as a tool call" do
      %{"messages" => messages} = body(unquote(id))

      assert [[%{"id" => "call_bad", "function" => %{"name" => "lookup_order", "arguments" => @args}}]] =
               for(%{"role" => "assistant", "tool_calls" => calls} <- messages, do: calls)
    end
  end

  test "OpenAI Responses sends it as a function call, without an id the API didn't issue" do
    %{"input" => input} = body("openai:gpt-5.4-mini")

    assert [call] = for(%{"type" => "function_call"} = item <- input, do: item)
    assert %{"call_id" => "call_bad", "name" => "lookup_order", "arguments" => @args} = call
    refute Map.has_key?(call, "id")
    assert [_output] = for(%{"type" => "function_call_output", "call_id" => "call_bad"} = item <- input, do: item)
  end

  defp body(id) do
    model = Models.init_chat_model!(id, api_key: "k")
    assert {:ok, body} = model.__struct__.request_body(model, history())
    body
  end

  defp history do
    [
      Message.user("Where is A-2?"),
      Message.assistant("", metadata: %{invalid_tool_calls: [@invalid]}),
      Message.tool(
        "Tool call lookup_order with id call_bad could not be executed - arguments were malformed or truncated.",
        tool_call_id: "call_bad",
        name: "lookup_order",
        metadata: %{status: "error"}
      ),
      Message.user("Try again.")
    ]
  end

  defp blocks(messages, role) do
    for %{"role" => ^role, "content" => content} <- messages, is_list(content), block <- content, do: block
  end
end
