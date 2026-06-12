defmodule BeamWeaver.Agent.UsageTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Agent.Usage
  alias BeamWeaver.Core.Message

  test "aggregates atom-key internal usage metadata and aliases" do
    usage =
      [
        Message.assistant("one", usage_metadata: %{prompt_tokens: 2, completion_tokens: 3, total: 5}),
        Message.assistant("two", usage_metadata: %{input_tokens: 1, output_tokens: 2, total_tokens: 3}),
        Message.tool("result", usage_metadata: %{input_tokens: 4, output_tokens: 0, total_tokens: 4})
      ]
      |> Usage.from_messages()

    assert usage.input_tokens == 7
    assert usage.output_tokens == 5
    assert usage.total_tokens == 12
    assert usage.model_calls == 2
    assert usage.tool_calls == 1
  end

  test "does not aggregate string-key maps as internal usage metadata" do
    usage =
      Usage.from_messages([
        Message.assistant("one", usage_metadata: %{"input_tokens" => 9, "output_tokens" => 9, "total_tokens" => 9})
      ])

    assert usage.input_tokens == 0
    assert usage.output_tokens == 0
    assert usage.total_tokens == 0
    assert usage.model_calls == 1
  end
end
