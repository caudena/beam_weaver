defmodule BeamWeaver.Anthropic.ChatModel.RequestBuilderTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Anthropic.ChatModel
  alias BeamWeaver.Anthropic.ChatModel.RequestBuilder
  alias BeamWeaver.Core.Message

  test "tools: nil is treated as no tools instead of raising" do
    model = ChatModel.new(model: "claude-sonnet-4-6")

    assert {:ok, body} = RequestBuilder.request_body(model, [Message.user("hi")], tools: nil)
    refute Map.has_key?(body, "tools")

    assert {:ok, count_body} = RequestBuilder.count_tokens_body(model, [Message.user("hi")], tools: nil)
    refute Map.has_key?(count_body, "tools")
  end
end
