defmodule BeamWeaver.Models.ProfileRegistry.Google do
  @moduledoc false

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Models.Profile
  alias BeamWeaver.Models.ProfileRegistry.Params

  @deprecated_google_models %{
    "gemini-3.1-flash-lite-preview" => %{
      shutdown_date: "2026-05-25",
      replacement: "gemini-3.1-flash-lite"
    },
    "gemini-3-flash-preview" => %{
      shutdown_date: nil,
      replacement: "gemini-3.5-flash"
    },
    "gemini-3-pro-preview" => %{
      shutdown_date: "2026-03-09",
      replacement: "gemini-3.1-pro-preview"
    },
    "gemini-2.5-pro" => %{
      shutdown_date: "2026-10-16",
      replacement: "gemini-3.1-pro-preview"
    },
    "gemini-2.5-pro-preview-03-25" => %{
      shutdown_date: "2025-12-02",
      replacement: "gemini-3.1-pro-preview"
    },
    "gemini-2.5-pro-preview-05-06" => %{
      shutdown_date: "2025-12-02",
      replacement: "gemini-3.1-pro-preview"
    },
    "gemini-2.5-pro-preview-06-05" => %{
      shutdown_date: "2025-12-02",
      replacement: "gemini-3.1-pro-preview"
    },
    "gemini-2.5-flash" => %{
      shutdown_date: "2026-10-16",
      replacement: "gemini-3.5-flash"
    },
    "gemini-2.5-flash-image" => %{
      shutdown_date: "2026-10-02",
      replacement: "gemini-3.1-flash-image-preview"
    },
    "gemini-2.5-flash-lite" => %{
      shutdown_date: "2026-10-16",
      replacement: "gemini-3.1-flash-lite"
    },
    "gemini-2.5-flash-lite-preview-09-2025" => %{
      shutdown_date: "2026-03-31",
      replacement: "gemini-3.1-flash-lite"
    },
    "gemini-2.5-flash-preview-05-20" => %{
      shutdown_date: "2025-11-18",
      replacement: "gemini-3.5-flash"
    },
    "gemini-2.5-flash-image-preview" => %{
      shutdown_date: "2026-01-15",
      replacement: "gemini-3.1-flash-image-preview"
    },
    "gemini-2.5-flash-preview-09-25" => %{
      shutdown_date: "2026-02-17",
      replacement: "gemini-3.5-flash"
    },
    "gemini-2.0-flash" => %{
      shutdown_date: "2026-06-01",
      replacement: "gemini-3.5-flash"
    },
    "gemini-2.0-flash-001" => %{
      shutdown_date: "2026-06-01",
      replacement: "gemini-3.5-flash"
    },
    "gemini-2.0-flash-lite" => %{
      shutdown_date: "2026-06-01",
      replacement: "gemini-3.1-flash-lite"
    },
    "gemini-2.0-flash-lite-001" => %{
      shutdown_date: "2026-06-01",
      replacement: "gemini-3.1-flash-lite"
    },
    "gemini-2.0-flash-preview-image-generation" => %{
      shutdown_date: "2025-11-14",
      replacement: "gemini-3.1-flash-image-preview"
    },
    "gemini-2.0-flash-lite-preview" => %{
      shutdown_date: "2025-12-09",
      replacement: "gemini-3.1-flash-lite"
    },
    "gemini-2.0-flash-lite-preview-02-05" => %{
      shutdown_date: "2025-12-09",
      replacement: "gemini-3.1-flash-lite"
    },
    "gemini-2.0-flash-live-001" => %{
      shutdown_date: "2025-12-09",
      replacement: "gemini-3.1-flash-live-preview"
    },
    "gemini-2.5-flash-native-audio-preview-12-2025" => %{
      shutdown_date: nil,
      replacement: "gemini-3.1-flash-live-preview"
    },
    "gemini-live-2.5-flash-preview" => %{
      shutdown_date: "2025-12-09",
      replacement: "gemini-3.1-flash-live-preview"
    },
    "gemini-2.5-flash-preview-tts" => %{
      shutdown_date: nil,
      replacement: "gemini-3.1-flash-tts-preview"
    },
    "gemini-2.5-pro-preview-tts" => %{
      shutdown_date: nil,
      replacement: "gemini-3.1-flash-tts-preview"
    }
  }

  @profiles %{
    {:google, "gemini-3.5-flash"} =>
      Profile.new(%{
        provider: :google,
        id: "gemini-3.5-flash",
        name: "Gemini 3.5 Flash",
        release_date: "2026-05-19",
        last_updated: "2026-05-19",
        max_input_tokens: 1_048_576,
        max_output_tokens: 65_536,
        text_inputs: true,
        image_inputs: true,
        image_url_inputs: true,
        audio_inputs: true,
        video_inputs: true,
        pdf_inputs: true,
        text_outputs: true,
        reasoning_output: true,
        tool_calling: true,
        tool_choice: true,
        parallel_tool_calls: true,
        structured_output: true,
        structured_output_max_schema_bytes: 8_000,
        structured_output_max_schema_properties: 80,
        streaming: true,
        usage_metadata: true,
        image_tool_message: true,
        pdf_tool_message: true,
        attachment: true,
        supported_params: Params.google(),
        extra: %{
          api_family: :gemini_developer,
          batch_api: true,
          caching: true,
          flex_inference: true,
          priority_inference: true,
          live_api: false,
          knowledge_cutoff: "2025-01",
          built_in_tools: [
            :code_execution,
            :file_search,
            :google_maps,
            :google_search,
            :url_context
          ],
          unsupported_tools: [:computer_use],
          grounding_metadata: true,
          safety_settings: true
        }
      }),
    {:google, "gemini-3.1-pro-preview"} =>
      Profile.new(%{
        provider: :google,
        id: "gemini-3.1-pro-preview",
        name: "Gemini 3.1 Pro Preview",
        release_date: "2026-02-19",
        last_updated: "2026-04-28",
        max_input_tokens: 1_048_576,
        max_output_tokens: 65_536,
        text_inputs: true,
        image_inputs: true,
        image_url_inputs: true,
        audio_inputs: true,
        video_inputs: true,
        pdf_inputs: true,
        text_outputs: true,
        reasoning_output: true,
        tool_calling: true,
        tool_choice: true,
        parallel_tool_calls: true,
        structured_output: true,
        structured_output_max_schema_bytes: 8_000,
        structured_output_max_schema_properties: 80,
        streaming: true,
        usage_metadata: true,
        image_tool_message: true,
        pdf_tool_message: true,
        attachment: true,
        supported_params: Params.google(),
        extra: %{
          api_family: :gemini_developer,
          batch_api: true,
          caching: true,
          flex_inference: true,
          priority_inference: true,
          live_api: false,
          knowledge_cutoff: "2025-01",
          built_in_tools: [
            :code_execution,
            :file_search,
            :google_maps,
            :google_search,
            :url_context
          ],
          file_search_scope: :ai_studio_only,
          unsupported_tools: [:computer_use],
          grounding_metadata: true,
          safety_settings: true
        }
      })
  }
  def profiles_map, do: @profiles
  def profiles, do: Map.values(@profiles)

  def resolve(model) do
    if Map.has_key?(@deprecated_google_models, model) do
      deprecated_model_error(model)
    else
      fetch_or_fallback(@profiles, :google, model)
    end
  end

  defp deprecated_model_error(model) do
    metadata = Map.fetch!(@deprecated_google_models, model)
    replacement = metadata.replacement

    {:error,
     Error.new(:deprecated_model, "Google model is deprecated or scheduled for shutdown", %{
       provider: :google,
       model: model,
       replacement: replacement,
       expected: "google:#{replacement}",
       shutdown_date: metadata.shutdown_date
     })}
  end

  defp fetch_or_fallback(profiles, provider, model) do
    case Map.fetch(profiles, {provider, model}) do
      {:ok, profile} -> {:ok, profile}
      :error -> {:fallback, provider, model}
    end
  end
end
