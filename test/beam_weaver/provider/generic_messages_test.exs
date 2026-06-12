defmodule BeamWeaver.Provider.GenericMessagesTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.ContentBlock
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Provider.DecodeMessage
  alias BeamWeaver.Provider.EncodeMessage

  test "generic provider translators preserve unknown content blocks" do
    message =
      Message.user([
        %{type: :text, text: "hello"},
        %{type: :reasoning, text: "because"}
      ])

    assert {:ok, encoded} = EncodeMessage.encode(message, provider: :groq)
    assert encoded.unknown_blocks == [%ContentBlock.Reasoning{reasoning: "because"}]

    assert {:ok, %Message{role: :user, content: content}} =
             DecodeMessage.decode(encoded, provider: :groq)

    assert content == message.content
  end
end
