defmodule BeamWeaver.Agent.MiddlewareHelpersTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Agent.Middleware.Helpers
  alias BeamWeaver.Agent.Middleware.Offload
  alias BeamWeaver.Core.Message

  test "append_prompt preserves nil prompts and appends to leading system messages" do
    system = Message.system("base")
    user = Message.user("hello")

    assert Helpers.append_prompt([user], nil) == [user]

    assert [%Message{role: :system, content: "base\n\nextra"}, ^user] =
             Helpers.append_prompt([system, user], "extra")

    assert [%Message{role: :system, content: "extra"}, ^user] =
             Helpers.append_prompt([user], "extra")
  end

  test "offload helpers sanitize ids, preview content, and preserve media blocks" do
    assert Offload.sanitize_tool_call_id("call/1.2\\3") == "call_1_2_3"

    preview =
      1..12
      |> Enum.map_join("\n", &"line #{&1}")
      |> Offload.content_preview(2, 2)

    assert preview =~ "     1\tline 1"
    assert preview =~ "... [8 lines truncated] ..."
    assert preview =~ "    12\tline 12"

    message =
      %Message{
        role: :tool,
        content: [
          %{type: :text, text: "old"},
          %{type: :image, source: "kept"}
        ]
      }

    assert [
             %{type: :text, text: "replacement"},
             %{type: :image, source: "kept"}
           ] = Offload.evicted_content(message, "replacement")
  end
end
