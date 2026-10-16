defmodule BeamWeaver.Provider.FallbackRepliesTest do
  # A reply from one provider or API sent to another, as after a model
  # fallback, goes as its text and tool calls.
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.Message
  alias BeamWeaver.Models

  @lookup %{"order_id" => "A-1001"}

  test "Chat Completions takes an Anthropic thinking reply as its text and tool calls" do
    for id <- ["openai:gpt-4.1", "xai:grok-4.6"] do
      model = Models.init_chat_model!(id, api: :chat_completions)
      assert {:ok, body} = model.__struct__.request_body(model, conversation(anthropic_reply(), "toolu_1"))

      assert [_user, assistant, tool] = body["messages"]

      assert assistant == %{
               "role" => "assistant",
               "content" => [%{"type" => "text", "text" => "Let me check."}],
               "tool_calls" => [
                 %{
                   "id" => "toolu_1",
                   "type" => "function",
                   "function" => %{"name" => "lookup_order", "arguments" => ~s({"order_id":"A-1001"})}
                 }
               ]
             }

      assert tool["tool_call_id"] == "toolu_1"
    end
  end

  test "Chat Completions takes a Responses API reply's calls by the ids their results answer" do
    model = Models.init_chat_model!("openai:gpt-4.1", api: :chat_completions)
    assert {:ok, body} = model.__struct__.request_body(model, conversation(responses_reply(), "call_1"))

    assert [_user, %{"content" => content, "tool_calls" => [call]}, %{"tool_call_id" => "call_1"}] = body["messages"]
    assert content == [%{"type" => "text", "text" => "Let me check."}]
    assert call["id"] == "call_1"
  end

  test "the Responses API takes another provider's or API's reply as its text and tool calls, without their ids" do
    model = Models.init_chat_model!("openai:gpt-5.4-mini")

    for {reply, call_id, text} <- [
          {anthropic_reply(), "toolu_1", "Let me check."},
          {chat_completions_reply(), "call_9", "Checking."}
        ] do
      assert {:ok, body} = model.__struct__.request_body(model, conversation(reply, call_id))

      assert [_user | items] = body["input"]

      assert items == [
               %{
                 "type" => "message",
                 "role" => "assistant",
                 "content" => [%{"type" => "output_text", "text" => text, "annotations" => []}]
               },
               %{
                 "type" => "function_call",
                 "call_id" => call_id,
                 "name" => "lookup_order",
                 "arguments" => ~s({"order_id":"A-1001"})
               },
               %{"type" => "function_call_output", "call_id" => call_id, "output" => "Shipped on Monday."}
             ]
    end
  end

  test "the Responses API still takes its own reply's items and reasoning" do
    model = Models.init_chat_model!("openai:gpt-5.4-mini")
    assert {:ok, body} = model.__struct__.request_body(model, conversation(responses_reply(), "call_1"))

    assert [_user, reasoning, message, call, _output] = body["input"]
    assert %{"type" => "reasoning", "id" => "rs_1", "encrypted_content" => "enc"} = reasoning
    assert %{"type" => "message", "id" => "msg_abc"} = message
    assert %{"type" => "function_call", "id" => "fc_1", "call_id" => "call_1"} = call
  end

  test "Anthropic takes a Responses API reply as its text and tool calls" do
    model = Models.init_chat_model!("anthropic:claude-haiku-4-5")
    assert {:ok, body} = model.__struct__.request_body(model, conversation(responses_reply(), "call_1"))

    assert [_user, %{"role" => "assistant", "content" => content}, %{"content" => [result]}] = body["messages"]
    assert [%{"type" => "text", "text" => "Let me check."}, tool_use] = content
    assert %{"type" => "tool_use", "name" => "lookup_order", "input" => @lookup, "id" => id} = tool_use
    assert result["tool_use_id"] == id
  end

  defp conversation(reply, call_id) do
    [
      Message.user("Where is order A-1001?"),
      reply,
      Message.tool("Shipped on Monday.", tool_call_id: call_id)
    ]
  end

  defp anthropic_reply do
    {:ok, reply} =
      BeamWeaver.Anthropic.Messages.response_to_message(%{
        "id" => "msg_1",
        "type" => "message",
        "role" => "assistant",
        "model" => "claude-haiku-4-5",
        "stop_reason" => "tool_use",
        "usage" => %{"input_tokens" => 10, "output_tokens" => 5},
        "content" => [
          %{"type" => "thinking", "thinking" => "The order needs a lookup.", "signature" => "sig_1"},
          %{"type" => "redacted_thinking", "data" => "opaque"},
          %{"type" => "text", "text" => "Let me check."},
          %{"type" => "tool_use", "id" => "toolu_1", "name" => "lookup_order", "input" => @lookup}
        ]
      })

    reply
  end

  defp responses_reply do
    {:ok, reply} =
      BeamWeaver.OpenAI.Messages.response_to_message(%{
        "id" => "resp_1",
        "object" => "response",
        "status" => "completed",
        "model" => "gpt-5.4-mini",
        "output" => [
          %{
            "type" => "reasoning",
            "id" => "rs_1",
            "summary" => [%{"type" => "summary_text", "text" => "The order needs a lookup."}],
            "encrypted_content" => "enc"
          },
          %{
            "type" => "message",
            "id" => "msg_abc",
            "role" => "assistant",
            "status" => "completed",
            "content" => [%{"type" => "output_text", "text" => "Let me check.", "annotations" => []}]
          },
          %{
            "type" => "function_call",
            "id" => "fc_1",
            "call_id" => "call_1",
            "name" => "lookup_order",
            "arguments" => ~s({"order_id":"A-1001"}),
            "status" => "completed"
          }
        ]
      })

    reply
  end

  defp chat_completions_reply do
    {:ok, reply} =
      BeamWeaver.OpenAI.ChatCompletions.Messages.response_to_message(%{
        "id" => "chatcmpl-1",
        "model" => "gpt-4.1",
        "choices" => [
          %{
            "index" => 0,
            "finish_reason" => "tool_calls",
            "message" => %{
              "role" => "assistant",
              "content" => "Checking.",
              "tool_calls" => [
                %{
                  "id" => "call_9",
                  "type" => "function",
                  "function" => %{"name" => "lookup_order", "arguments" => ~s({"order_id":"A-1001"})}
                }
              ]
            }
          }
        ]
      })

    reply
  end
end
