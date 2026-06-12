defmodule BeamWeaver.Agent.ModelRequestTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Agent.ModelRequest
  alias BeamWeaver.Core.Message

  test "normalizes string system prompts into system messages" do
    request =
      ModelRequest.new(
        system_prompt: "You are helpful",
        messages: [Message.user("hi")]
      )

    assert %Message{role: :system, content: "You are helpful"} = request.system_message
    assert ModelRequest.system_prompt(request) == "You are helpful"
    assert request.messages == [Message.user("hi")]
  end

  test "override preserves immutability and can reset the system prompt" do
    original =
      ModelRequest.new(system_message: Message.system("Original", metadata: %{source: "base"}))

    updated = ModelRequest.override(original, system_prompt: "Updated")
    reset = ModelRequest.override(updated, system_prompt: nil)

    assert ModelRequest.system_prompt(original) == "Original"
    assert original.system_message.metadata == %{source: "base"}
    assert ModelRequest.system_prompt(updated) == "Updated"
    assert reset.system_message == nil
  end

  test "override rejects conflicting system message inputs" do
    request = ModelRequest.new()

    assert_raise ArgumentError, ~r/cannot specify both/, fn ->
      ModelRequest.override(request,
        system_prompt: "String prompt",
        system_message: Message.system("Message prompt")
      )
    end
  end

  test "system prompt helper handles structured system content" do
    request =
      ModelRequest.new(
        system_message:
          Message.system([
            %{"type" => "text", "text" => "Part 1"},
            %{
              "type" => "text",
              "text" => "Part 2",
              "cache_control" => %{"type" => "ephemeral"}
            }
          ])
      )

    assert ModelRequest.system_prompt(request) =~ "Part 1"
    assert Enum.at(request.system_message.content, 1).cache_control == %{"type" => "ephemeral"}
  end

  test "string-key overrides do not create arbitrary atom fields" do
    request =
      ModelRequest.new()
      |> ModelRequest.override(%{
        "system_prompt" => "From string key",
        "unknown_runtime_key" => "ignored"
      })

    assert ModelRequest.system_prompt(request) == "From string key"
    refute Map.has_key?(request, :unknown_runtime_key)
  end
end
