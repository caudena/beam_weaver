defmodule BeamWeaver.Anthropic.MessagesTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Anthropic.Messages
  alias BeamWeaver.Core.ContentBlock
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Messages.ToolCall
  alias BeamWeaver.Provider.DecodeMessage
  alias BeamWeaver.Provider.EncodeMessage

  test "lifts system messages, appends missing assistant tool_use blocks, and formats tool results" do
    messages = [
      Message.system("You are terse."),
      Message.user("lookup beam"),
      Message.assistant("calling",
        tool_calls: [%ToolCall{id: "toolu_1", name: "lookup", args: %{"q" => "beam"}}]
      ),
      Message.tool("Beam is an Elixir VM", tool_call_id: "toolu_1")
    ]

    assert {:ok, {system, formatted}} = Messages.format_messages(messages)
    assert system == "You are terse."

    assert [
             %{"role" => "user", "content" => "lookup beam"},
             %{"role" => "assistant", "content" => assistant_content},
             %{"role" => "user", "content" => [tool_result]}
           ] = formatted

    assert assistant_content == [
             %{"type" => "text", "text" => "calling"},
             %{
               "type" => "tool_use",
               "id" => "toolu_1",
               "name" => "lookup",
               "input" => %{"q" => "beam"}
             }
           ]

    assert tool_result == %{
             "type" => "tool_result",
             "content" => "Beam is an Elixir VM",
             "tool_use_id" => "toolu_1",
             "is_error" => false
           }
  end

  test "normalizes cross-provider tool ids only at the Anthropic boundary" do
    openai_call_id = "call_openai_weather_123"

    assistant =
      Message.assistant("calling",
        tool_calls: [%ToolCall{id: openai_call_id, name: "lookup", args: %{"q" => "beam"}}]
      )

    tool_result = Message.tool("Beam is an Elixir VM", tool_call_id: openai_call_id)

    assert {:ok, {_system, formatted}} =
             Messages.format_messages([
               Message.user("lookup beam"),
               assistant,
               tool_result
             ])

    assert [
             %{"role" => "user"},
             %{"role" => "assistant", "content" => [_text, tool_use]},
             %{"role" => "user", "content" => [result]}
           ] = formatted

    assert %{"type" => "tool_use", "id" => "toolu_bw_" <> _digest} = tool_use
    assert result["tool_use_id"] == tool_use["id"]
    refute tool_use["id"] == openai_call_id
    assert hd(assistant.tool_calls).id == openai_call_id
    assert tool_result.tool_call_id == openai_call_id

    assert {:ok, {_system, repeated}} = Messages.format_messages([assistant, tool_result])
    [%{"content" => [_text, repeated_tool_use]}, %{"content" => [repeated_result]}] = repeated
    assert repeated_tool_use["id"] == tool_use["id"]
    assert repeated_result["tool_use_id"] == tool_use["id"]
  end

  test "formats image and document blocks for Anthropic" do
    assert {:ok, {_system, [%{"content" => content}]}} =
             Messages.format_messages([
               Message.user([
                 ContentBlock.image(%{url: "data:image/png;base64,QUJD"}),
                 ContentBlock.file(%{data: "Rk9P", mime_type: "application/pdf"})
               ])
             ])

    assert [
             %{
               "type" => "image",
               "source" => %{"type" => "base64", "media_type" => "image/png", "data" => "QUJD"}
             },
             %{
               "type" => "document",
               "source" => %{
                 "type" => "base64",
                 "media_type" => "application/pdf",
                 "data" => "Rk9P"
               }
             }
           ] = content
  end

  test "decodes Anthropic responses with usage, citations, thinking, and tool calls" do
    response = %{
      "id" => "msg_123",
      "type" => "message",
      "role" => "assistant",
      "model" => "claude-haiku-4-5-20251001",
      "stop_reason" => "tool_use",
      "stop_details" => %{
        "type" => "refusal",
        "category" => "safety",
        "explanation" => "policy refusal"
      },
      "content" => [
        %{
          "type" => "text",
          "text" => "I found it.",
          "citations" => [
            %{"type" => "web_search_result_location", "url" => "https://example.test"}
          ]
        },
        %{"type" => "thinking", "thinking" => "Need a lookup", "signature" => "sig"},
        %{
          "type" => "tool_use",
          "id" => "toolu_1",
          "name" => "lookup",
          "input" => %{"q" => "beam"}
        }
      ],
      "usage" => %{
        "input_tokens" => 10,
        "cache_read_input_tokens" => 2,
        "cache_creation" => %{"ephemeral_5m_input_tokens" => 3},
        "output_tokens" => 5
      }
    }

    assert {:ok, %Message{} = message} = Messages.response_to_message(response)
    assert message.id == "msg_123"
    assert message.status == "tool_use"
    assert message.response_metadata.model_provider == "anthropic"
    assert message.response_metadata.stop_details["category"] == "safety"

    assert message.tool_calls == [
             %ToolCall{
               id: "toolu_1",
               provider_id: "toolu_1",
               call_id: "toolu_1",
               name: "lookup",
               args: %{"q" => "beam"}
             }
           ]

    assert message.usage_metadata == %{
             input_tokens: 15,
             output_tokens: 5,
             total_tokens: 20,
             input_token_details: %{
               cache_read: 2,
               cache_creation: 0,
               ephemeral_5m_input_tokens: 3
             }
           }

    assert Enum.any?(message.content, &(&1.type == :reasoning))
    assert Enum.any?(message.content, &(&1.type == :tool_call))
  end

  test "provider protocols route Anthropic through the Anthropic translator" do
    assert {:ok, %{"role" => "user", "content" => "hello"}} =
             EncodeMessage.encode(Message.user("hello"), provider: :anthropic)

    payload = %{"content" => [%{"type" => "text", "text" => "hi"}]}

    assert {:ok, %Message{role: :assistant, content: "hi"}} =
             DecodeMessage.decode(payload, provider: :anthropic)
  end
end
