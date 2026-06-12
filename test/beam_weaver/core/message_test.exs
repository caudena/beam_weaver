defmodule BeamWeaver.Core.MessageTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.ContentBlock
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Messages
  alias BeamWeaver.Core.Messages.ToolCall
  alias BeamWeaver.MapShape

  test "extracts text from string content and text content blocks" do
    assert Message.text(Message.user("hello")) == "hello"

    message =
      Message.user([
        ContentBlock.text("typed "),
        %{"type" => "text", "text" => "hello "},
        %{"type" => "plain_text", "text" => "plain "},
        %{"text" => "bare "},
        %{"type" => "image", "url" => "https://example.test/cat.png"},
        %{type: :text, text: "world"},
        %{text: "!"}
      ])

    assert Message.text(message) == "typed hello plain bare world!"
  end

  test "extracts ChatGeneration-style text while ignoring non-text blocks" do
    assert Message.text(Message.assistant(["foo", "bar"])) == "foobar"

    assert Message.text(
             Message.assistant([
               %{"type" => "text", "text" => "foo"},
               %{"type" => "reasoning", "reasoning" => "..."},
               %{"type" => "text", "text" => "bar"},
               %{"type" => "tool_use", "tool_use" => %{}}
             ])
           ) == "foobar"

    assert Message.text(Message.assistant([])) == ""
  end

  test "normalizes message content blocks through typed block protocol" do
    payload = Base.encode64("png bytes")

    message =
      Message.user([
        "caption",
        %{"type" => "image", "url" => "data:image/png;base64,#{payload}"},
        %{"type" => "citation", "url" => "https://example.test", "start_index" => 2}
      ])

    assert {:ok,
            [
              %ContentBlock.Text{text: "caption"},
              %ContentBlock.Image{data: ^payload, mime_type: "image/png"},
              %ContentBlock.Citation{url: "https://example.test", start_index: 2}
            ]} = Message.content_blocks(message)
  end

  test "projects string-key content maps into atom-native message content" do
    message =
      Message.assistant([
        %{"type" => "text", "text" => "hello", "id" => "msg-1"},
        %{
          "type" => "image_url",
          "image_url" => %{"url" => "https://example.test/cat.png", "detail" => "high"}
        },
        %{"type" => "tool_use", "id" => "call-1", "name" => "lookup", "input" => %{"q" => "beam"}},
        %{"type" => "vendor.private", "payload" => %{"deep" => true}}
      ])

    assert [
             %{type: :text, text: "hello", id: "msg-1"} = text_block,
             %ContentBlock.Image{url: "https://example.test/cat.png", metadata: %{detail: "high"}},
             %{type: :tool_use, id: "call-1", name: "lookup", args: %{"q" => "beam"}} =
               tool_block,
             %ContentBlock.Unknown{provider_type: "vendor.private", value: raw_unknown}
           ] = message.content

    assert Message.text(message) == "hello"
    assert MapShape.assert_atom_keys!(text_block)
    assert MapShape.assert_atom_keys!(tool_block)
    assert MapShape.assert_string_keys!(tool_block.args)
    assert MapShape.assert_string_keys!(raw_unknown)
    assert raw_unknown["payload"] == %{"deep" => true}
  end

  test "assistant content blocks include reasoning and missing tool calls" do
    message =
      Message.assistant(
        [
          %{type: :text, text: "answer"},
          %{type: :tool_call, id: "call-present", name: "lookup", args: %{}}
        ],
        metadata: %{reasoning_content: "plan"},
        tool_calls: [
          %ToolCall{id: "call-present", name: "lookup", args: %{}},
          %ToolCall{id: "call-missing", name: "search", args: %{"q" => "beam"}}
        ]
      )

    assert {:ok,
            [
              %ContentBlock.Reasoning{reasoning: "plan"},
              %{type: :text, text: "answer"},
              %{type: :tool_call, id: "call-present", name: "lookup"},
              %{type: :tool_call, id: "call-missing", name: "search", args: %{"q" => "beam"}}
            ]} = Message.content_blocks(message)
  end

  test "tool message content follows ToolMessage coercion behavior at the native boundary" do
    assert %Message{role: :tool, content: "42", tool_call_id: "123"} =
             Message.tool(42, tool_call_id: 123)

    assert %Message{
             role: :tool,
             content: [
               %ContentBlock.Text{text: "ok"},
               %ContentBlock.Text{text: "12"},
               %{type: :text, text: "done"}
             ]
           } =
             Message.tool({"ok", 12, %{type: :text, text: "done"}})
  end

  test "raw provider tool calls parse into native call and invalid-call structs" do
    assert {:ok,
            %{
              tool_calls: [
                %Messages.ToolCall{
                  id: "call-1",
                  name: "search",
                  args: %{"q" => "beam"},
                  type: :tool_call
                }
              ],
              invalid_tool_calls: [
                %Messages.InvalidToolCall{
                  id: "call-2",
                  name: "broken",
                  args: "{",
                  type: :invalid_tool_call
                }
              ]
            }} =
             Messages.parse_tool_calls([
               %{
                 "id" => "call-1",
                 "function" => %{"name" => "search", "arguments" => ~s({"q":"beam"})}
               },
               %{"id" => "ignored"},
               %{"id" => "call-2", "function" => %{"name" => "broken", "arguments" => "{"}}
             ])

    assert {:ok,
            [
              %Messages.ToolCallChunk{
                id: "call-1",
                index: 0,
                name: "search",
                args: "{\"q\":"
              },
              %Messages.ToolCallChunk{id: "call-1", index: 0, args: "\"beam\"}"}
            ]} =
             Messages.parse_tool_call_chunks([
               %{
                 "id" => "call-1",
                 "index" => 0,
                 "function" => %{"name" => "search", "arguments" => "{\"q\":"}
               },
               %{"id" => "call-1", "index" => 0, "function" => %{"arguments" => "\"beam\"}"}}
             ])
  end

  test "rejects unsupported roles and content shapes" do
    assert {:error, role_error} = Message.new(:developer, "hello")
    assert role_error.type == :invalid_role

    assert {:error, content_error} = Message.new(:user, 123)
    assert content_error.type == :invalid_content
  end

  test "validates persistent message field shapes" do
    message = %Message{role: :assistant, content: "", tool_calls: [%{name: "lookup"}]}
    assert :ok = Message.validate(message)

    assert {:error, %{type: :invalid_tool_call}} =
             Message.validate(%{message | tool_calls: [:bad]})

    assert {:error, %{type: :invalid_message}} =
             Message.validate(%{message | response_metadata: []})
  end
end
