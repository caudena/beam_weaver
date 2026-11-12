defmodule BeamWeaver.Models.ProfileRegistry.Moonshot do
  @moduledoc false

  alias BeamWeaver.Models.Profile
  alias BeamWeaver.Models.ProfileRegistry
  alias BeamWeaver.Models.ProfileRegistry.Params

  @context_window 262_144
  @k3_context_window 1_048_576
  @profile_last_updated "2026-11-12"
  @default_model "kimi-k3.1-pro"
  @k3_models [@default_model, "kimi-k3.1-pro-highspeed", "kimi-k3"]
  @k2_models ~w(kimi-k2.7-code kimi-k2.7-code-highspeed kimi-k2.6)
  @k3_responses_params [
    :instructions,
    :stream,
    :max_output_tokens,
    :reasoning,
    :reasoning_effort,
    :text,
    :response_format,
    :structured_output,
    :tools,
    :tool_choice,
    :include,
    :prompt_cache_key,
    :prompt_cache_options,
    :safety_identifier
  ]
  @k3_supported_params [:reasoning_effort, :prompt_cache_options | Params.moonshot()] -- [:thinking]

  @moonshot_deprecated_models %{
    "moonshot-v1-8k" => %{replacement: "kimi-k3", discontinued_at: "2026-08-31"},
    "moonshot-v1-32k" => %{replacement: "kimi-k3", discontinued_at: "2026-08-31"},
    "moonshot-v1-128k" => %{replacement: "kimi-k3", discontinued_at: "2026-08-31"},
    "moonshot-v1-auto" => %{replacement: "kimi-k3", discontinued_at: "2026-08-31"},
    "moonshot-v1-8k-vision-preview" => %{replacement: "kimi-k3", discontinued_at: "2026-08-31"},
    "moonshot-v1-32k-vision-preview" => %{replacement: "kimi-k3", discontinued_at: "2026-08-31"},
    "moonshot-v1-128k-vision-preview" => %{replacement: "kimi-k3", discontinued_at: "2026-08-31"},
    "kimi-k2.5" => %{replacement: "kimi-k3", discontinued_at: "2026-08-31"},
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
    pricing_last_checked: "2026-11-12",
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
    thinking_always_enabled: true,
    dynamic_tool_loading: true,
    tool_choice_when_thinking: ["auto", "none", "required"],
    web_search_supported: false,
    web_search_status: :updating,
    responses_web_search: true
  }

  @k3_profile Map.merge(@base_profile, %{
                max_input_tokens: @k3_context_window,
                max_output_tokens: @k3_context_window,
                responses_api: true,
                supported_params: @k3_supported_params,
                supported_params_by_api: %{
                  chat_completions: @k3_supported_params,
                  responses: @k3_responses_params
                },
                reasoning_effort_levels: [:low, :high, :max],
                reasoning_effort_default: :max
              })

  @k3_profiles (for {id, name, input, cached, output, extras} <- [
                      {@default_model, "Kimi K3.1 Pro", 2.00, 0.20, 10.00,
                       %{cache_write_1h_price_per_mtok: 4.00, batch_api: true}},
                      {"kimi-k3.1-pro-highspeed", "Kimi K3.1 Pro Highspeed", 4.00, 0.20, 20.00,
                       %{cache_write_1h_price_per_mtok: 8.00, highspeed: true, same_model_as: @default_model}},
                      {"kimi-k3", "Kimi K3", 3.00, 0.30, 15.00, %{cache_write_1h_price_per_mtok: 6.00, batch_api: true}}
                    ],
                    into: %{} do
                  extra =
                    @base_extra
                    |> Map.merge(@k3_extra)
                    |> Map.merge(%{
                      api_families: [:chat_completions, :responses],
                      unsupported_api_families: [:embeddings, :batch, :files],
                      model_category: :flagship,
                      native_visual_understanding: true,
                      default_max_completion_tokens: 131_072,
                      input_cache_hit_price_per_mtok: cached,
                      input_cache_miss_price_per_mtok: input,
                      cache_write_5m_price_per_mtok: input,
                      output_price_per_mtok: output
                    })
                    |> Map.merge(extras)

                  {{:moonshot, id},
                   Profile.new(
                     Map.merge(@k3_profile, %{
                       id: id,
                       name: name,
                       release_date: if(id != "kimi-k3", do: "2026-10-23"),
                       extra: extra
                     })
                   )}
                end)

  @profiles [
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
                     json_mode_only: true,
                     pricing_source_url: "https://platform.kimi.ai/docs/pricing/chat-k26",
                     input_cache_hit_price_per_mtok: 0.16,
                     input_cache_miss_price_per_mtok: 0.95,
                     output_price_per_mtok: 4.00,
                     batch_input_cache_hit_price_per_mtok: 0.10,
                     batch_input_cache_miss_price_per_mtok: 0.57,
                     batch_output_price_per_mtok: 2.40
                   })
               }}
            ]
            |> Map.new(fn {id, profile} ->
              {{:moonshot, id}, Profile.new(Map.merge(@base_profile, profile))}
            end)
            |> Map.merge(@k3_profiles)

  @profiles Map.new(@profiles, fn {key, profile} ->
              extra =
                profile.extra
                |> Map.put(:input_price_per_mtok, profile.extra.input_cache_miss_price_per_mtok)
                |> Map.put(:cached_input_price_per_mtok, profile.extra.input_cache_hit_price_per_mtok)
                |> Map.put(:pricing_source_url, "https://platform.kimi.ai/docs/pricing/chat")
                |> Map.put(:standalone_tool_pricing, %{
                  search: %{price_per_1000_requests: 2.0, billing: :successful_nonempty_response},
                  search_pro: %{price_per_1000_requests: 3.0, billing: :successful_nonempty_response},
                  fetch: %{price_per_1000_requests: 2.0, billing: :successful_nonempty_response}
                })
                |> Map.put(:tool_pricing_source_url, "https://platform.kimi.ai/docs/pricing/websearch")

              profile =
                if profile.id in @k2_models do
                  extra =
                    Map.merge(extra, %{
                      existing_accounts_only_since: "2026-10-31",
                      retirement_window: "late December 2026",
                      recommended_replacement: @default_model
                    })

                  %{profile | status: :deprecated, extra: extra}
                else
                  %{profile | extra: extra}
                end

              {key, profile}
            end)

  def default_model, do: @default_model
  def k3_models, do: @k3_models
  def k3_model?(model), do: model in @k3_models
  def profiles, do: Map.values(@profiles)

  def resolve(model) do
    case @moonshot_deprecated_models[model] do
      nil -> ProfileRegistry.fetch_or_fallback(@profiles, :moonshot, model)
      metadata -> ProfileRegistry.deprecated_error(:moonshot, model, "Moonshot/Kimi model is discontinued", metadata)
    end
  end
end
