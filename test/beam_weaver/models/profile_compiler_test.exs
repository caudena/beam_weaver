defmodule BeamWeaver.Models.ProfileCompilerTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Models.Profile
  alias BeamWeaver.Models.ProfileCompiler

  test "compile_provider captures models.dev fields, omits absent values and sorts by id" do
    data = %{
      "anthropic" => %{
        "models" => %{
          "z-model" => %{
            "id" => "z-model",
            "name" => "Claude Opus 4.6",
            "status" => "deprecated",
            "release_date" => "2025-06-01",
            "last_updated" => "2025-07-01",
            "open_weights" => false,
            "reasoning" => true,
            "tool_call" => true,
            "tool_call_streaming" => true,
            "tool_choice" => true,
            "structured_output" => true,
            "attachment" => true,
            "temperature" => false,
            "limit" => %{"context" => 200_000, "output" => 64_000},
            "modalities" => %{
              "input" => ["text", "image", "pdf"],
              "output" => ["text"]
            }
          },
          "a-model" => %{
            "modalities" => %{"input" => ["text"], "output" => ["text"]},
            "limit" => %{"context" => 8_192, "output" => 4_096}
          }
        }
      }
    }

    assert {:ok, [minimal, profile]} = ProfileCompiler.compile_provider(data, "anthropic")

    assert %Profile{provider: :anthropic, id: "z-model", extra: extra} = profile
    assert extra == %{}
    assert profile.name == "Claude Opus 4.6"
    assert profile.status == "deprecated"
    assert profile.release_date == "2025-06-01"
    assert profile.last_updated == "2025-07-01"
    assert profile.open_weights == false
    assert profile.max_input_tokens == 200_000
    assert profile.max_output_tokens == 64_000
    assert profile.reasoning_output == true
    assert profile.tool_calling == true
    assert profile.tool_call_streaming == true
    assert profile.tool_choice == true
    assert profile.structured_output == true
    assert profile.attachment == true
    assert profile.temperature == false
    assert profile.text_inputs == true
    assert profile.image_inputs == true
    assert profile.pdf_inputs == true
    assert profile.text_outputs == true

    assert %Profile{id: "a-model", status: nil, temperature: true, tool_calling: false, extra: %{}} = minimal
  end

  test "compile_provider maps text modalities explicitly" do
    models = %{
      "a-text" => %{"modalities" => %{"input" => ["text", "image"], "output" => ["text"]}},
      "b-audio" => %{"modalities" => %{"input" => ["audio"], "output" => ["text"]}},
      "c-image" => %{"modalities" => %{"input" => ["text"], "output" => ["image"]}, "limit" => %{}}
    }

    assert {:ok, [text, audio, image]} =
             ProfileCompiler.compile_provider(%{"anthropic" => %{"models" => models}}, :anthropic)

    assert {text.text_inputs, text.text_outputs} == {true, true}
    assert {audio.text_inputs, audio.text_outputs} == {false, true}
    assert {image.text_inputs, image.text_outputs} == {true, false}
  end

  test "compile_provider returns tagged errors for missing providers" do
    assert {:error, error} = ProfileCompiler.compile_provider(%{"openai" => %{}}, "anthropic")
    assert error.type == :missing_profile_provider
    assert error.details.provider == "anthropic"
  end
end
