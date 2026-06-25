defmodule BeamWeaver.Models.ProfileCompilerTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Models.Profile
  alias BeamWeaver.Models.ProfileCompiler

  test "model_data_to_profile captures models.dev fields and omits absent values" do
    profile =
      ProfileCompiler.model_data_to_profile(%{
        "id" => "claude-opus-4-6",
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
        "temperature" => true,
        "limit" => %{"context" => 200_000, "output" => 64_000},
        "modalities" => %{
          "input" => ["text", "image", "pdf"],
          "output" => ["text"]
        }
      })

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
    assert profile.text_inputs == true
    assert profile.image_inputs == true
    assert profile.pdf_inputs == true
    assert profile.text_outputs == true

    minimal =
      ProfileCompiler.model_data_to_profile(%{
        "modalities" => %{"input" => ["text"], "output" => ["text"]},
        "limit" => %{"context" => 8_192, "output" => 4_096}
      })

    refute Map.has_key?(minimal, :status)
    refute Map.has_key?(minimal, :family)
    refute nil in Map.values(minimal)
  end

  test "model_data_to_profile maps text modalities explicitly" do
    text_model =
      ProfileCompiler.model_data_to_profile(%{
        "modalities" => %{"input" => ["text", "image"], "output" => ["text"]},
        "limit" => %{"context" => 128_000, "output" => 4_096}
      })

    assert text_model.text_inputs == true
    assert text_model.text_outputs == true

    audio_only =
      ProfileCompiler.model_data_to_profile(%{
        "modalities" => %{"input" => ["audio"], "output" => ["text"]},
        "limit" => %{"context" => 0, "output" => 0}
      })

    assert audio_only.text_inputs == false
    assert audio_only.text_outputs == true

    image_output =
      ProfileCompiler.model_data_to_profile(%{
        "modalities" => %{"input" => ["text"], "output" => ["image"]},
        "limit" => %{}
      })

    assert image_output.text_inputs == true
    assert image_output.text_outputs == false
  end

  test "compiled profile keys are declared by Profile" do
    profile =
      ProfileCompiler.model_data_to_profile(%{
        "id" => "test-model",
        "name" => "Test Model",
        "status" => "active",
        "release_date" => "2025-01-01",
        "last_updated" => "2025-01-01",
        "open_weights" => true,
        "reasoning" => true,
        "tool_call" => true,
        "tool_call_streaming" => true,
        "tool_choice" => true,
        "structured_output" => true,
        "attachment" => true,
        "temperature" => true,
        "image_url_inputs" => true,
        "image_tool_message" => true,
        "pdf_tool_message" => true,
        "pdf_inputs" => true,
        "limit" => %{"context" => 100_000, "output" => 4_096},
        "modalities" => %{
          "input" => ["text", "image", "audio", "video", "pdf"],
          "output" => ["text", "image", "audio", "video"]
        }
      })

    assert :ok = ProfileCompiler.validate_keys([profile])
  end

  test "validate_keys reports undeclared profile fields without dynamic imports" do
    assert {:error, error} =
             ProfileCompiler.validate_keys([
               %{:max_input_tokens => 100, "future_key" => true},
               %{another_key: "value"}
             ])

    assert error.type == :undeclared_profile_keys
    assert error.details.keys == [:another_key, "future_key"]

    assert :ok =
             ProfileCompiler.validate_keys([
               %{max_input_tokens: 100, tool_calling: true, tool_call_streaming: true}
             ])
  end

  test "compile_provider applies overrides, includes override-only models, and sorts output" do
    data = %{
      "anthropic" => %{
        "models" => %{
          "z-model" => %{
            "id" => "z-model",
            "name" => "Z Model",
            "tool_call" => true,
            "limit" => %{"context" => 100_000, "output" => 2_048},
            "modalities" => %{"input" => ["text"], "output" => ["text"]}
          },
          "a-model" => %{
            "id" => "a-model",
            "name" => "A Model",
            "tool_call" => false,
            "limit" => %{"context" => 50_000, "output" => 1_024},
            "modalities" => %{"input" => ["text"], "output" => ["text"]}
          }
        }
      }
    }

    assert {:ok, profiles} =
             ProfileCompiler.compile_provider(data, "anthropic",
               provider_overrides: %{image_url_inputs: true},
               model_overrides: %{
                 "custom-offline-model" => %{
                   structured_output: true,
                   pdf_inputs: true,
                   max_input_tokens: 123
                 },
                 "a-model" => %{tool_calling: true}
               }
             )

    assert Enum.map(profiles, & &1.id) == ["a-model", "custom-offline-model", "z-model"]
    assert Enum.all?(profiles, &match?(%Profile{provider: :anthropic}, &1))
    assert Enum.all?(profiles, &(&1.image_url_inputs == true))
    assert Enum.find(profiles, &(&1.id == "a-model")).tool_calling == true

    custom = Enum.find(profiles, &(&1.id == "custom-offline-model"))
    assert custom.structured_output == true
    assert custom.pdf_inputs == true
    assert custom.max_input_tokens == 123
  end

  test "compile_provider returns tagged errors for missing providers" do
    assert {:error, error} = ProfileCompiler.compile_provider(%{"openai" => %{}}, "anthropic")
    assert error.type == :missing_profile_provider
    assert error.details.provider == "anthropic"
  end
end
