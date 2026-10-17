defmodule BeamWeaver.OutputParser.OpenAITest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Messages
  alias BeamWeaver.OutputParser

  test "parse_tools returns an empty list for an AIChunk with no tool calls" do
    chunk = %Messages.AIChunk{tool_calls: [], tool_call_chunks: []}

    assert {:ok, []} = OutputParser.parse_openai_tools(chunk)
  end

  test "parse_tools returns an empty list for a Chunk with no tool calls" do
    chunk = %Messages.Chunk{tool_calls: [], tool_call_chunks: []}

    assert {:ok, []} = OutputParser.parse_openai_tools(chunk)
  end

  test "parse_tools returns an empty list for a Message with nil tool_calls" do
    message = %Message{role: :assistant, content: "done", tool_calls: nil}

    assert {:ok, []} = OutputParser.parse_openai_tools(message)
  end
end
