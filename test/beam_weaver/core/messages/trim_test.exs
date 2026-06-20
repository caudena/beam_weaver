defmodule BeamWeaver.Core.Messages.TrimTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.ContentBlock
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Messages.Trim

  defp word_counter do
    fn
      %Message{content: content} when is_list(content) ->
        Enum.reduce(content, 0, fn
          %ContentBlock.Text{text: text}, acc -> acc + length(String.split(text || "", ~r/\s+/, trim: true))
          _block, acc -> acc
        end)

      %Message{content: content} when is_binary(content) ->
        length(String.split(content, ~r/\s+/, trim: true))

      _other ->
        0
    end
  end

  test "partial list content under strategy :last keeps the trailing words" do
    message = %Message{
      role: :user,
      content: [%ContentBlock.Text{text: "alpha beta gamma delta epsilon"}]
    }

    {:ok, [trimmed]} =
      Trim.trim([message], max_tokens: 2, token_counter: word_counter(), strategy: :last, allow_partial: true)

    assert [%ContentBlock.Text{text: "delta epsilon"}] = trimmed.content
  end

  test "partial list content under strategy :first keeps the leading words" do
    message = %Message{
      role: :user,
      content: [%ContentBlock.Text{text: "alpha beta gamma delta epsilon"}]
    }

    {:ok, [trimmed]} =
      Trim.trim([message], max_tokens: 2, token_counter: word_counter(), strategy: :first, allow_partial: true)

    assert [%ContentBlock.Text{text: "alpha beta"}] = trimmed.content
  end
end
