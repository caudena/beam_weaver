defmodule BeamWeaver.Models.ProfileRegistry.Moonshot do
  @moduledoc false

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Models.Profile
  alias BeamWeaver.Models.ProfileRegistry.Params

  @context_window 262_144
  @k3_context_window 1_048_576
  @profile_last_updated "2026-07-19"
  @k3_supported_params [:reasoning_effort | Params.moonshot()] -- [:thinking]

  @moonshot_deprecated_models %{
    "kimi-latest" => %{
      replacement: "kimi-k3",
      discontinued_at: "2026-01-28"
    },
    "kimi-thinking-preview" => %{
      replacement: "kimi-k3",
      discontinued_at: "2025-11-11"
    },
    "kimi-k2-0905-preview" => %{
      replacement: "kimi-k3",
      discontinued_at: "2026-05-25"
    },
    "kimi-k2-0711-preview" => %{
      replacement: "kimi-k3",
      discontinued_at: "2026-05-25"
    },
    "kimi-k2-turbo-preview" => %{
      replacement: "kimi-k3",
      discontinued_at: "2026-05-25"
    },
    "kimi-k2-thinking" => %{
      replacement: "kimi-k3",
      discontinued_at: "2026-05-25"
    },
    "kimi-k2-thinking-turbo" => %{
      replacement: "kimi-k3",
      discontinued_at: "2026-05-25"
    }
  }

  @base_profile %{
    provider: :moonshot,
    status: :active,
    last_updated: @profile_last_updated,
    max_input_tokens: @context_window,
    max_output_tokens: nil,
    text_inputs: true,
    image_inputs: true,
    image_url_inputs: true,
    video_inputs: true,
    text_outputs: true,
    reasoning_output: true,
    tool_calling: true,
    tool_call_streaming: true,
    tool_choice: true,
    parallel_tool_calls: true,
    structured_output: true,
    streaming: true,
    usage_metadata: true,
    chat_completions_api: true,
    attachment: true,
    supported_params: Params.moonshot(),
    supported_params_by_api: %{
      chat_completions: Params.moonshot()
    },
    tokenizer: :o200k_base
  }

  @base_extra %{
    api_family: :chat_completions,
    openai_compatible: true,
    automatic_context_caching: true,
    partial_mode: true,
    unsupported_api_families: [:responses, :embeddings, :batch, :files],
    sampling_controls: :fixed
  }

  @thinking_toggle_extra %{
    built_in_tools: ["$web_search"],
    thinking_modes: [:enabled, :disabled],
    web_search_requires_thinking_disabled: true
  }

  @thinking_required_extra %{
    thinking_modes: [:enabled],
    non_thinking_mode: false,
    tool_choice_when_thinking: ["auto", "none"],
    web_search_supported: false
  }

  @k3_extra %{
    reasoning_efforts: [:max],
    default_reasoning_effort: :max,
    thinking_always_enabled: true,
    dynamic_tool_loading: true,
    tool_choice_when_thinking: ["auto", "none", "required"],
    web_search_supported: false,
    web_search_status: :updating
  }

  @profiles [
              {"kimi-k3",
               %{
                 id: "kimi-k3",
                 name: "Kimi K3",
                 max_input_tokens: @k3_context_window,
                 max_output_tokens: @k3_context_window,
                 supported_params: @k3_supported_params,
                 supported_params_by_api: %{
                   chat_completions: @k3_supported_params
                 },
                 extra:
                   Map.merge(@base_extra, @k3_extra)
                   |> Map.merge(%{
                     model_category: :flagship,
                     native_visual_understanding: true,
                     default_max_completion_tokens: 131_072,
                     pricing_source_url: "https://platform.kimi.ai/docs/pricing/chat-k3",
                     input_cache_hit_price_per_mtok: 0.30,
                     input_cache_miss_price_per_mtok: 3.00,
                     output_price_per_mtok: 15.00
                   })
               }},
              {"kimi-k2.7-code",
               %{
                 id: "kimi-k2.7-code",
                 name: "Kimi K2.7 Code",
                 extra:
                   Map.merge(@base_extra, @thinking_required_extra)
                   |> Map.merge(%{
                     model_category: :coding,
                     pricing_source_url: "https://platform.kimi.ai/docs/pricing/chat-k27-code",
                     input_cache_hit_price_per_mtok: 0.19,
                     input_cache_miss_price_per_mtok: 0.95,
                     output_price_per_mtok: 4.00
                   })
               }},
              {"kimi-k2.7-code-highspeed",
               %{
                 id: "kimi-k2.7-code-highspeed",
                 name: "Kimi K2.7 Code HighSpeed",
                 extra:
                   Map.merge(@base_extra, @thinking_required_extra)
                   |> Map.merge(%{
                     model_category: :coding,
                     highspeed: true,
                     same_model_as: "kimi-k2.7-code",
                     pricing_source_url: "https://platform.kimi.ai/docs/pricing/chat-k27-code",
                     output_speed_tokens_per_second: 180,
                     short_context_output_speed_tokens_per_second: 260,
                     input_cache_hit_price_per_mtok: 0.38,
                     input_cache_miss_price_per_mtok: 1.90,
                     output_price_per_mtok: 8.00
                   })
               }},
              {"kimi-k2.6",
               %{
                 id: "kimi-k2.6",
                 name: "Kimi K2.6",
                 release_date: "2026-05-25",
                 extra:
                   Map.merge(@base_extra, @thinking_toggle_extra)
                   |> Map.merge(%{
                     input_cache_hit_price_per_mtok: 0.16,
                     input_cache_miss_price_per_mtok: 0.95,
                     output_price_per_mtok: 4.00,
                     batch_input_cache_hit_price_per_mtok: 0.10,
                     batch_input_cache_miss_price_per_mtok: 0.57,
                     batch_output_price_per_mtok: 2.40
                   })
               }},
              {"kimi-k2.5",
               %{
                 id: "kimi-k2.5",
                 name: "Kimi K2.5",
                 status: :deprecated,
                 extra:
                   Map.merge(@base_extra, @thinking_toggle_extra)
                   |> Map.merge(%{
                     unavailable_to_new_users: true,
                     sunset_at: "2026-08-31",
                     input_cache_hit_price_per_mtok: 0.10,
                     input_cache_miss_price_per_mtok: 0.60,
                     output_price_per_mtok: 3.00
                   })
               }}
            ]
            |> Map.new(fn {id, profile} ->
              {{:moonshot, id}, Profile.new(Map.merge(@base_profile, profile))}
            end)

  def profiles_map, do: @profiles
  def profiles, do: Map.values(@profiles)

  def resolve(model) do
    if Map.has_key?(@moonshot_deprecated_models, model) do
      deprecated_model_error(model)
    else
      fetch_or_fallback(@profiles, :moonshot, model)
    end
  end

  defp deprecated_model_error(model) do
    metadata = Map.fetch!(@moonshot_deprecated_models, model)
    replacement = metadata.replacement

    {:error,
     Error.new(:deprecated_model, "Moonshot/Kimi model is discontinued", %{
       provider: :moonshot,
       model: model,
       replacement: replacement,
       expected: "moonshot:#{replacement}",
       discontinued_at: metadata.discontinued_at
     })}
  end

  defp fetch_or_fallback(profiles, provider, model) do
    case Map.fetch(profiles, {provider, model}) do
      {:ok, profile} -> {:ok, profile}
      :error -> {:fallback, provider, model}
    end
  end
end
