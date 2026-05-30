defmodule BeamWeaver.Agent.StateTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Agent.State
  alias BeamWeaver.Core.Message
  alias BeamWeaver.MapShape

  test "projects string-key public input into atom-key internal state" do
    messages = [Message.user("hello")]

    state =
      State.project(%{
        "messages" => messages,
        "jump_to" => "tools",
        "structured_response" => %{"answer" => "ok"},
        "external" => %{"kept" => true}
      })

    assert state.messages == messages
    assert state.jump_to == "tools"
    assert state.structured_response == %{"answer" => "ok"}
    assert state.raw_input == %{"external" => %{"kept" => true}}
    assert MapShape.assert_atom_keys!(state)
    assert MapShape.assert_string_keys!(state.raw_input)
  end

  test "preserves atom-key extras as internal state" do
    state = State.project(%{messages: [], scratch: %{count: 1}})

    assert state == %{messages: [], scratch: %{count: 1}}
    assert MapShape.assert_atom_keys!(state)
  end

  test "projects schema-known atom fields without creating atoms from unknown strings" do
    state =
      State.project(
        %{
          "scratch" => "known",
          "unknown" => "raw"
        },
        %{scratch: :last_value}
      )

    assert state.scratch == "known"
    assert state.raw_input == %{"unknown" => "raw"}
    assert MapShape.assert_atom_keys!(state)
  end

  test "atom keys win over string aliases for known state fields" do
    messages = [Message.user("atom")]

    state =
      State.project(Map.merge(%{"messages" => [Message.user("string")]}, %{messages: messages}))

    assert state == %{messages: messages}
  end

  test "normalizes jump routing from atom and string aliases" do
    assert State.jump_to(%{jump_to: "model"}) == :model
    assert State.jump_to(%{jump_to: :tools}) == :tools
    assert State.jump_to(%{"jump_to" => "end"}) == :end
  end
end
