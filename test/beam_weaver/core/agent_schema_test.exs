defmodule BeamWeaver.Core.AgentSchemaTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.AgentAction
  alias BeamWeaver.Core.AgentActionMessageLog
  alias BeamWeaver.Core.AgentFinish
  alias BeamWeaver.Core.AgentStep
  alias BeamWeaver.Core.Message

  test "agent actions preserve action fields and replay assistant log messages" do
    action = AgentAction.new("search", %{"q" => "elixir"}, "Thought: search")

    assert action.tool == "search"
    assert action.tool_input == %{"q" => "elixir"}
    assert action.type == "AgentAction"
    assert AgentAction.serializable?()
    assert [%Message{role: :assistant, content: "Thought: search"}] = AgentAction.messages(action)
  end

  test "agent action message logs replay the original chat messages" do
    action =
      AgentActionMessageLog.new(
        "lookup",
        "2",
        "ignored when message_log exists",
        [
          {"system", "rules"},
          Message.assistant("Call lookup")
        ]
      )

    assert action.type == "AgentActionMessageLog"
    assert AgentActionMessageLog.serializable?()

    assert [
             %Message{role: :system, content: "rules"},
             %Message{role: :assistant, content: "Call lookup"}
           ] = AgentActionMessageLog.messages(action)
  end

  test "agent steps convert observations to user or function-style messages" do
    plain = AgentAction.new("search", "beam", "searching")

    assert [%Message{role: :user, content: ~s({"answer":"κόσμος"})}] =
             AgentStep.new(plain, %{"answer" => "κόσμος"}) |> AgentStep.messages()

    logged = AgentActionMessageLog.new("lookup", "beam", "calling", [Message.assistant("call")])

    assert [
             %Message{
               role: :assistant,
               name: "lookup",
               content: "done",
               metadata: %{}
             }
           ] = AgentStep.new(logged, "done") |> AgentStep.messages()
  end

  test "agent finish replays final assistant log" do
    finish = AgentFinish.new(%{"output" => "42"}, "Final Answer: 42")

    assert finish.type == "AgentFinish"
    assert AgentFinish.serializable?()

    assert [%Message{role: :assistant, content: "Final Answer: 42"}] =
             AgentFinish.messages(finish)
  end
end
