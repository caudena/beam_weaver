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
    "gemini-2.5-flash-image" => %{
      shutdown_date: "2026-10-02",
      replacement: "gemini-3.1-flash-image-preview"
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

  @unavailable_google_models %{
    "gemini-3.5-flash-cyber" => %{
      access: :codemender_limited_access,
      reason: "Gemini 3.5 Flash Cyber is limited to governments and trusted partners through CodeMender"
    }
  }

  @profiles %{
    {:google, "gemini-3.8-flash"} =>
      Profile.new(%{
        provider: :google,
        id: "gemini-3.8-flash",
        name: "Gemini 3.8 Flash",
        status: :active,
        release_date: "2026-09-02",
        last_updated: "2026-09-02",
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
        supported_params: Params.google_latest_flash(),
        extra: %{
          api_family: :gemini_developer,
          batch_api: true,
          caching: true,
          flex_inference: true,
          priority_inference: true,
          live_api: false,
          input_price_per_mtok: 0.75,
          cached_input_price_per_mtok: 0.075,
          output_price_per_mtok: 3.75,
          batch_input_price_per_mtok: 0.375,
          batch_cached_input_price_per_mtok: 0.0375,
          batch_output_price_per_mtok: 1.875,
          flex_input_price_per_mtok: 0.375,
          flex_cached_input_price_per_mtok: 0.0375,
          flex_output_price_per_mtok: 1.875,
          priority_input_price_per_mtok: 1.35,
          priority_cached_input_price_per_mtok: 0.135,
          priority_output_price_per_mtok: 6.75,
          context_cache_storage_price_per_mtok_hour: 0.50,
          pricing_source_url: "https://ai.google.dev/gemini-api/docs/pricing",
          introductory_pricing_through: "2026-12-31",
          regular_input_price_per_mtok: 1.50,
          regular_cached_input_price_per_mtok: 0.15,
          regular_output_price_per_mtok: 7.50,
          default_thinking_level: :medium,
          thinking_levels: [:low, :medium, :high],
          prefilled_model_turns: false,
          built_in_tools: [
            :code_execution,
            :computer_use,
            :file_search,
            :google_maps,
            :google_search,
            :url_context
          ],
          computer_use: :preview,
          grounding_metadata: true,
          safety_settings: true
        }
      }),
    {:google, "gemini-3.7-flash"} =>
      Profile.new(%{
        provider: :google,
        id: "gemini-3.7-flash",
        name: "Gemini 3.7 Flash",
        status: :active,
        release_date: "2026-08-13",
        last_updated: "2026-08-13",
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
        supported_params: Params.google_latest_flash(),
        extra: %{
          api_family: :gemini_developer,
          batch_api: true,
          caching: true,
          flex_inference: true,
          priority_inference: true,
          live_api: false,
          input_price_per_mtok: 0.75,
          cached_input_price_per_mtok: 0.075,
          output_price_per_mtok: 3.75,
          batch_input_price_per_mtok: 0.375,
          batch_cached_input_price_per_mtok: 0.0375,
          batch_output_price_per_mtok: 1.875,
          flex_input_price_per_mtok: 0.375,
          flex_cached_input_price_per_mtok: 0.0375,
          flex_output_price_per_mtok: 1.875,
          priority_input_price_per_mtok: 1.35,
          priority_cached_input_price_per_mtok: 0.135,
          priority_output_price_per_mtok: 6.75,
          context_cache_storage_price_per_mtok_hour: 0.50,
          pricing_source_url: "https://ai.google.dev/gemini-api/docs/pricing",
          introductory_pricing_through: "2026-12-31",
          regular_input_price_per_mtok: 1.50,
          regular_cached_input_price_per_mtok: 0.15,
          regular_output_price_per_mtok: 7.50,
          default_thinking_level: :medium,
          thinking_levels: [:low, :medium, :high],
          prefilled_model_turns: false,
          built_in_tools: [
            :code_execution,
            :computer_use,
            :file_search,
            :google_maps,
            :google_search,
            :url_context
          ],
          computer_use: :preview,
          grounding_metadata: true,
          safety_settings: true
        }
      }),
    {:google, "gemini-3.6-flash"} =>
      Profile.new(%{
        provider: :google,
        id: "gemini-3.6-flash",
        name: "Gemini 3.6 Flash",
        status: :active,
        release_date: "2026-07-21",
        last_updated: "2026-08-27",
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
        supported_params: Params.google_latest_flash(),
        extra: %{
          api_family: :gemini_developer,
          batch_api: true,
          caching: true,
          flex_inference: true,
          priority_inference: true,
          live_api: false,
          input_price_per_mtok: 0.75,
          cached_input_price_per_mtok: 0.075,
          output_price_per_mtok: 3.75,
          batch_input_price_per_mtok: 0.375,
          batch_cached_input_price_per_mtok: 0.0375,
          batch_output_price_per_mtok: 1.875,
          flex_input_price_per_mtok: 0.375,
          flex_cached_input_price_per_mtok: 0.0375,
          flex_output_price_per_mtok: 1.875,
          priority_input_price_per_mtok: 1.35,
          priority_cached_input_price_per_mtok: 0.135,
          priority_output_price_per_mtok: 6.75,
          context_cache_storage_price_per_mtok_hour: 0.50,
          pricing_source_url: "https://ai.google.dev/gemini-api/docs/pricing",
          introductory_pricing_through: "2026-12-31",
          regular_input_price_per_mtok: 1.50,
          regular_cached_input_price_per_mtok: 0.15,
          regular_output_price_per_mtok: 7.50,
          default_thinking_level: :medium,
          prefilled_model_turns: false,
          built_in_tools: [
            :code_execution,
            :computer_use,
            :file_search,
            :google_maps,
            :google_search,
            :url_context
          ],
          computer_use: :preview,
          grounding_metadata: true,
          safety_settings: true
        }
      }),
    {:google, "gemini-3.5-flash"} =>
      Profile.new(%{
        provider: :google,
        id: "gemini-3.5-flash",
        name: "Gemini 3.5 Flash",
        release_date: "2026-05-19",
        last_updated: "2026-08-27",
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
          input_price_per_mtok: 1.50,
          cached_input_price_per_mtok: 0.15,
          output_price_per_mtok: 9.00,
          batch_input_price_per_mtok: 0.75,
          batch_cached_input_price_per_mtok: 0.075,
          batch_output_price_per_mtok: 4.50,
          flex_input_price_per_mtok: 0.75,
          flex_cached_input_price_per_mtok: 0.08,
          flex_output_price_per_mtok: 4.50,
          priority_input_price_per_mtok: 2.70,
          priority_cached_input_price_per_mtok: 0.27,
          priority_output_price_per_mtok: 16.20,
          context_cache_storage_price_per_mtok_hour: 1.00,
          pricing_source_url: "https://ai.google.dev/gemini-api/docs/pricing",
          built_in_tools: [
            :code_execution,
            :computer_use,
            :file_search,
            :google_maps,
            :google_search,
            :url_context
          ],
          computer_use: :preview,
          grounding_metadata: true,
          safety_settings: true
        }
      }),
    {:google, "gemini-3.5-flash-lite"} =>
      Profile.new(%{
        provider: :google,
        id: "gemini-3.5-flash-lite",
        name: "Gemini 3.5 Flash-Lite",
        status: :active,
        release_date: "2026-07-21",
        last_updated: "2026-07-21",
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
        supported_params: Params.google_latest_flash(),
        extra: %{
          api_family: :gemini_developer,
          batch_api: true,
          caching: true,
          flex_inference: true,
          priority_inference: true,
          live_api: false,
          input_price_per_mtok: 0.30,
          cached_input_price_per_mtok: 0.03,
          output_price_per_mtok: 2.50,
          batch_input_price_per_mtok: 0.15,
          batch_cached_input_price_per_mtok: 0.02,
          batch_output_price_per_mtok: 1.25,
          flex_input_price_per_mtok: 0.15,
          flex_cached_input_price_per_mtok: 0.02,
          flex_output_price_per_mtok: 1.25,
          priority_input_price_per_mtok: 0.54,
          priority_cached_input_price_per_mtok: 0.05,
          priority_output_price_per_mtok: 4.50,
          context_cache_storage_price_per_mtok_hour: 1.00,
          default_thinking_level: :minimal,
          prefilled_model_turns: false,
          built_in_tools: [
            :code_execution,
            :computer_use,
            :file_search,
            :google_maps,
            :google_search,
            :url_context
          ],
          computer_use: :preview,
          grounding_metadata: true,
          safety_settings: true
        }
      }),
    {:google, "gemini-3.1-flash-lite"} =>
      Profile.new(%{
        provider: :google,
        id: "gemini-3.1-flash-lite",
        name: "Gemini 3.1 Flash-Lite",
        status: :active,
        release_date: "2026-05-07",
        last_updated: "2026-08-27",
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
          input_price_per_mtok: 0.25,
          audio_input_price_per_mtok: 0.50,
          cached_input_price_per_mtok: 0.025,
          cached_audio_input_price_per_mtok: 0.05,
          output_price_per_mtok: 1.50,
          batch_input_price_per_mtok: 0.125,
          batch_audio_input_price_per_mtok: 0.25,
          batch_cached_input_price_per_mtok: 0.0125,
          batch_cached_audio_input_price_per_mtok: 0.025,
          batch_output_price_per_mtok: 0.75,
          flex_input_price_per_mtok: 0.125,
          flex_audio_input_price_per_mtok: 0.25,
          flex_cached_input_price_per_mtok: 0.0125,
          flex_cached_audio_input_price_per_mtok: 0.025,
          flex_output_price_per_mtok: 0.75,
          priority_input_price_per_mtok: 0.45,
          priority_audio_input_price_per_mtok: 0.90,
          priority_cached_input_price_per_mtok: 0.045,
          priority_cached_audio_input_price_per_mtok: 0.09,
          priority_output_price_per_mtok: 2.70,
          context_cache_storage_price_per_mtok_hour: 1.00,
          priority_context_cache_storage_price_per_mtok_hour: 1.80,
          pricing_source_url: "https://ai.google.dev/gemini-api/docs/pricing",
          scheduled_shutdown_date: "2027-05-07",
          recommended_replacement: "gemini-3.5-flash-lite",
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
        last_updated: "2026-08-27",
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
          input_price_per_mtok: 2.00,
          cached_input_price_per_mtok: 0.20,
          output_price_per_mtok: 12.00,
          higher_context_pricing_threshold_tokens: 200_000,
          higher_context_input_price_per_mtok: 4.00,
          higher_context_cached_input_price_per_mtok: 0.40,
          higher_context_output_price_per_mtok: 18.00,
          batch_input_price_per_mtok: 1.00,
          batch_output_price_per_mtok: 6.00,
          higher_context_batch_input_price_per_mtok: 2.00,
          higher_context_batch_output_price_per_mtok: 9.00,
          flex_input_price_per_mtok: 1.00,
          flex_output_price_per_mtok: 6.00,
          higher_context_flex_input_price_per_mtok: 2.00,
          higher_context_flex_output_price_per_mtok: 9.00,
          priority_input_price_per_mtok: 3.60,
          priority_cached_input_price_per_mtok: 0.36,
          priority_output_price_per_mtok: 21.60,
          higher_context_priority_input_price_per_mtok: 7.20,
          higher_context_priority_cached_input_price_per_mtok: 0.72,
          higher_context_priority_output_price_per_mtok: 32.40,
          context_cache_storage_price_per_mtok_hour: 4.50,
          priority_context_cache_storage_price_per_mtok_hour: 8.10,
          pricing_source_url: "https://ai.google.dev/gemini-api/docs/pricing",
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
    cond do
      Map.has_key?(@deprecated_google_models, model) ->
        deprecated_model_error(model)

      Map.has_key?(@unavailable_google_models, model) ->
        unavailable_model_error(model)

      true ->
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

  defp unavailable_model_error(model) do
    metadata = Map.fetch!(@unavailable_google_models, model)

    {:error,
     Error.new(:unsupported_model, "Google model is not available through the Gemini API", %{
       provider: :google,
       model: model,
       access: metadata.access,
       reason: metadata.reason
     })}
  end

  defp fetch_or_fallback(profiles, provider, model) do
    case Map.fetch(profiles, {provider, model}) do
      {:ok, profile} -> {:ok, profile}
      :error -> {:fallback, provider, model}
    end
  end
end
