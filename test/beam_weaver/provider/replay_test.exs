defmodule BeamWeaver.Provider.ReplayTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Anthropic.Messages, as: AnthropicMessages
  alias BeamWeaver.Core.ContentBlock
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Messages.ToolCall
  alias BeamWeaver.Google.Messages, as: GoogleMessages
  alias BeamWeaver.OpenAI.Messages, as: OpenAIMessages
  alias BeamWeaver.Provider.Replay

  test "round trips Anthropic signed thinking" do
    binding = replay_binding("anthropic")

    message =
      Message.assistant([
        ContentBlock.reasoning("private summary", %{signature: "signed-thinking"}),
        ContentBlock.text("answer")
      ])

    assert {:ok, projection} = Replay.project(message, binding)
    assert {:ok, restored} = Replay.restore(projection, binding)
    assert {:ok, {_system, [%{"content" => content}]}} = AnthropicMessages.format_messages([restored])

    assert %{"type" => "thinking", "thinking" => "private summary", "signature" => "signed-thinking"} in content
  end

  test "round trips Anthropic fallback boundary blocks" do
    fallback = %{
      "type" => "fallback",
      "from" => %{"model" => "claude-opus-5"},
      "to" => %{"model" => "claude-opus-4-8"}
    }

    response = %{
      "id" => "msg_fallback",
      "type" => "message",
      "role" => "assistant",
      "model" => "claude-opus-4-8",
      "stop_reason" => "end_turn",
      "content" => [fallback, %{"type" => "text", "text" => "fallback answer"}],
      "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
    }

    binding = replay_binding("anthropic")

    assert {:ok, message} = AnthropicMessages.response_to_message(response)
    assert {:ok, projection} = Replay.project(message, binding)
    assert {:ok, restored} = Replay.restore(projection, binding)
    assert {:ok, {_system, [%{"content" => content}]}} = AnthropicMessages.format_messages([restored])

    assert [^fallback, %{"type" => "text", "text" => "fallback answer"}] = content
  end

  test "round trips Gemini thought signatures on text and tool calls" do
    binding = replay_binding("google")

    message =
      Message.assistant(
        [ContentBlock.text("answer", %{thought_signature: "sig-text"})],
        tool_calls: [
          %ToolCall{
            id: "call-1",
            name: "lookup",
            args: %{"query" => "beam"},
            thought_signature: "sig-tool"
          }
        ]
      )

    assert {:ok, projection} = Replay.project(message, binding)
    assert {:ok, restored} = Replay.restore(projection, binding)
    assert {:ok, {_system, [%{"parts" => parts}]}} = GoogleMessages.encode_messages([restored])

    assert %{"text" => "answer", "thoughtSignature" => "sig-text"} in parts

    assert %{
             "functionCall" => %{"name" => "lookup", "args" => %{"query" => "beam"}},
             "thoughtSignature" => "sig-tool"
           } in parts
  end

  test "round trips OpenAI encrypted reasoning and provider correlation ids" do
    binding = replay_binding("openai")

    message =
      Message.assistant(
        [
          %{
            type: :reasoning,
            id: "reasoning-1",
            status: "completed",
            summary: [],
            encrypted_content: "encrypted-reasoning"
          }
        ],
        tool_calls: [
          %ToolCall{
            id: "call-1",
            provider_id: "function-1",
            call_id: "provider-call-1",
            name: "lookup",
            args: %{"query" => "beam"}
          }
        ]
      )

    assert {:ok, projection} = Replay.project(message, binding)
    assert {:ok, restored} = Replay.restore(projection, binding)
    assert {:ok, input} = OpenAIMessages.to_responses_input([restored], store: false)

    assert %{
             "type" => "reasoning",
             "status" => "completed",
             "summary" => [],
             "encrypted_content" => "encrypted-reasoning"
           } in input

    assert %{
             "type" => "function_call",
             "call_id" => "provider-call-1",
             "name" => "lookup"
           } = Enum.find(input, &(&1["type"] == "function_call"))
  end

  test "rejects replay under a different provider binding" do
    assert {:ok, projection} = Replay.project(Message.assistant("answer"), replay_binding("anthropic"))

    assert {:error, %{type: :provider_replay_binding_mismatch}} =
             Replay.restore(projection, replay_binding("openai"))
  end

  test "checks bindings without materializing replay content" do
    binding = replay_binding("anthropic")
    assert {:ok, projection} = Replay.project(Message.assistant("answer"), binding)

    assert Replay.binding_matches?(projection, binding)
    refute Replay.binding_matches?(projection, replay_binding("openai"))
    refute Replay.binding_matches?(%{"version" => 2, "binding" => binding}, binding)
    refute Replay.binding_matches?(%{"version" => 1}, binding)
  end

  test "rejects unknown blocks instead of restoring a partial replay" do
    binding = replay_binding("anthropic")

    assert {:ok, projection} = Replay.project(Message.assistant("answer"), binding)
    projection = %{projection | "content" => [%{"type" => "future_provider_block"}]}

    assert {:error, %{type: :invalid_provider_replay}} = Replay.restore(projection, binding)
  end

  test "reapplies the replay size bound while restoring persisted projections" do
    binding = replay_binding("anthropic")
    assert {:ok, projection} = Replay.project(Message.assistant("answer"), binding)

    oversized =
      Map.put(projection, "content", [
        %{"type" => "text", "text" => String.duplicate("x", 8 * 1024 * 1024)}
      ])

    assert {:error, %{type: :provider_replay_too_large}} = Replay.restore(oversized, binding)
  end

  test "rejects malformed tool calls during projection and restoration" do
    binding = replay_binding("google")

    malformed = Message.assistant("answer", tool_calls: [%{id: "call-1", args: %{}}])
    assert {:error, %{type: :invalid_provider_replay}} = Replay.project(malformed, binding)

    valid =
      Message.assistant("answer",
        tool_calls: [%ToolCall{id: "call-1", name: "lookup", args: %{}}]
      )

    assert {:ok, projection} = Replay.project(valid, binding)
    projection = %{projection | "tool_calls" => [%{"id" => "call-1", "arguments" => %{}}]}

    assert {:error, %{type: :invalid_provider_replay}} = Replay.restore(projection, binding)
  end

  defp replay_binding(provider) do
    %{
      provider: provider,
      dialect: provider <> "_dialect",
      destination: "https://provider.example.test",
      principal: "principal-hash",
      model: "model-1",
      profile: "profile-1",
      configuration: "configuration-hash"
    }
  end
end
