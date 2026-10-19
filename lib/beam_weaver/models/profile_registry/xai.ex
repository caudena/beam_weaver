defmodule BeamWeaver.Models.ProfileRegistry.XAI do
  @moduledoc false

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Models.Profile
  alias BeamWeaver.Models.ProfileRegistry
  alias BeamWeaver.Models.ProfileRegistry.Params

  @xai_deprecated_models %{
    "grok-4-1-fast-reasoning" => %{replacement: "grok-4.3", reasoning_effort: "low"},
    "grok-4-1-fast-non-reasoning" => %{replacement: "grok-4.3", reasoning_effort: "none"},
    "grok-4-fast-reasoning" => %{replacement: "grok-4.3", reasoning_effort: "low"},
    "grok-4-fast-non-reasoning" => %{replacement: "grok-4.3", reasoning_effort: "none"},
    "grok-4-0709" => %{replacement: "grok-4.3", reasoning_effort: "low"},
    "grok-code-fast-1" => %{replacement: "grok-build-0.1"},
    "grok-3" => %{replacement: "grok-4.3", reasoning_effort: "none"},
    "grok-imagine-image-pro" => %{replacement: "grok-imagine-image-quality"}
  }

  @xai_chat_aliases %{
    "grok-4.5-latest" => "grok-4.5",
    "grok-build-latest" => "grok-4.5",
    "grok-latest" => "grok-4.3",
    "grok-4.3-latest" => "grok-4.3",
    "grok-4" => "grok-4.3",
    "grok-4-latest" => "grok-4.3",
    "grok-4-fast" => "grok-4.3",
    "grok-4-fast-reasoning-latest" => "grok-4.3",
    "grok-4-fast-non-reasoning-latest" => "grok-4.3",
    "grok-4-1-fast" => "grok-4.3",
    "grok-4-1-fast-reasoning-latest" => "grok-4.3",
    "grok-4-1-fast-non-reasoning-latest" => "grok-4.3",
    "grok-3-latest" => "grok-4.3",
    "grok-3-beta" => "grok-4.3",
    "grok-3-fast" => "grok-4.3",
    "grok-3-fast-latest" => "grok-4.3",
    "grok-3-fast-beta" => "grok-4.3",
    "grok-3-mini" => "grok-4.3",
    "grok-3-mini-latest" => "grok-4.3",
    "grok-3-mini-beta" => "grok-4.3",
    "grok-3-mini-fast" => "grok-4.3",
    "grok-3-mini-fast-latest" => "grok-4.3",
    "grok-3-mini-fast-beta" => "grok-4.3",
    "grok-3-mini-high" => "grok-4.3",
    "grok-3-mini-high-beta" => "grok-4.3",
    "grok-3-mini-fast-high" => "grok-4.3",
    "grok-3-mini-fast-high-beta" => "grok-4.3",
    "grok-4.20" => "grok-4.20-0309-reasoning",
    "grok-4.20-0309" => "grok-4.20-0309-reasoning",
    "grok-4.20-reasoning" => "grok-4.20-0309-reasoning",
    "grok-4.20-reasoning-latest" => "grok-4.20-0309-reasoning",
    "grok-4.20-beta" => "grok-4.20-0309-reasoning",
    "grok-4.20-beta-0309" => "grok-4.20-0309-reasoning",
    "grok-4.20-beta-0309-reasoning" => "grok-4.20-0309-reasoning",
    "grok-4.20-beta-latest" => "grok-4.20-0309-reasoning",
    "grok-4.20-beta-latest-reasoning" => "grok-4.20-0309-reasoning",
    "grok-4.20-beta-reasoning" => "grok-4.20-0309-reasoning",
    "grok-4.20-non-reasoning" => "grok-4.20-0309-non-reasoning",
    "grok-4.20-non-reasoning-latest" => "grok-4.20-0309-non-reasoning",
    "grok-4.20-beta-non-reasoning" => "grok-4.20-0309-non-reasoning",
    "grok-4.20-beta-latest-non-reasoning" => "grok-4.20-0309-non-reasoning",
    "grok-4.20-beta-0309-non-reasoning" => "grok-4.20-0309-non-reasoning",
    "grok-code-fast" => "grok-build-0.1",
    "grok-code-fast-1-0825" => "grok-build-0.1",
    "grok-4.20-multi-agent" => "grok-4.20-multi-agent-0309",
    "grok-4.20-multi-agent-latest" => "grok-4.20-multi-agent-0309",
    "grok-4.20-multi-agent-beta-latest" => "grok-4.20-multi-agent-0309",
    "grok-4.20-multi-agent-beta-0309" => "grok-4.20-multi-agent-0309"
  }

  @xai_non_chat_models %{
    "grok-imagine-image-2.0" => "grok-imagine image APIs are not exposed through chat models",
    "grok-imagine-video-1.5" => "grok-imagine video APIs are not exposed through chat models",
    "grok-imagine-video-1.5-lite" => "grok-imagine video APIs are not exposed through chat models",
    "grok-imagine-image" => "grok-imagine image APIs are not exposed through chat models",
    "grok-imagine-image-quality" => "grok-imagine image APIs are not exposed through chat models",
    "grok-imagine-video" => "grok-imagine video APIs are not exposed through chat models"
  }

  @grok_profile %{
    provider: :xai,
    responses_api: true,
    chat_completions_api: true,
    text_inputs: true,
    image_inputs: true,
    image_url_inputs: true,
    pdf_inputs: true,
    text_outputs: true,
    reasoning_output: true,
    tool_calling: true,
    tool_call_streaming: true,
    tool_choice: true,
    parallel_tool_calls: true,
    structured_output: true,
    streaming: true,
    usage_metadata: true,
    attachment: true,
    supported_params: Params.xai_responses(),
    supported_params_by_api: %{
      responses: Params.xai_responses(),
      chat_completions: Params.xai_chat_completions()
    },
    tokenizer: :o200k_base
  }

  @grok_4_20_extra %{
    input_price_per_mtok: 1.25,
    cached_input_price_per_mtok: 0.20,
    output_price_per_mtok: 2.50,
    higher_context_pricing_threshold_tokens: 200_000,
    higher_context_input_price_per_mtok: 2.50,
    higher_context_cached_input_price_per_mtok: 0.40,
    higher_context_output_price_per_mtok: 5.00,
    batch_discount_rate: 0.20
  }

  @profiles %{
    {:xai, "grok-4.7"} =>
      Profile.new(
        Map.merge(@grok_profile, %{
          id: "grok-4.7",
          name: "Grok 4.7",
          status: :active,
          release_date: "2026-09-21",
          last_updated: "2026-10-16",
          max_input_tokens: 500_000,
          reasoning_effort_default: :high,
          reasoning_effort_levels: [:low, :medium, :high, :xhigh],
          extra: %{
            frontier: true,
            knowledge_cutoff: "2026-05-01",
            text_output_limit: :unlimited,
            input_price_per_mtok: 2.00,
            cached_input_price_per_mtok: 0.50,
            output_price_per_mtok: 6.00,
            higher_context_pricing_threshold_tokens: 200_000,
            higher_context_input_price_per_mtok: 4.00,
            higher_context_cached_input_price_per_mtok: 1.00,
            higher_context_output_price_per_mtok: 12.00,
            cost_currency: "USD",
            pricing_source_url: "https://docs.x.ai/developers/pricing",
            pricing_modes: [:standard, :priority],
            priority_processing_price_multiplier: 2.0,
            priority_processing_service_tier: :priority,
            regions: ["us-east-1", "us-west-2", "us-central-1"]
          }
        })
      ),
    {:xai, "grok-4.6"} =>
      Profile.new(
        Map.merge(@grok_profile, %{
          id: "grok-4.6",
          name: "Grok 4.6",
          status: :active,
          release_date: "2026-08-12",
          last_updated: "2026-08-12",
          max_input_tokens: 500_000,
          reasoning_effort_default: :high,
          reasoning_effort_levels: [:low, :medium, :high, :xhigh],
          extra: %{
            frontier: true,
            knowledge_cutoff: "2026-02-01",
            text_output_limit: :unlimited,
            input_price_per_mtok: 2.00,
            cached_input_price_per_mtok: 0.50,
            output_price_per_mtok: 6.00,
            higher_context_pricing_threshold_tokens: 200_000,
            higher_context_input_price_per_mtok: 4.00,
            higher_context_cached_input_price_per_mtok: 1.00,
            higher_context_output_price_per_mtok: 12.00,
            cost_currency: "USD",
            pricing_source_url: "https://docs.x.ai/developers/pricing",
            pricing_modes: [:standard, :priority],
            priority_processing_price_multiplier: 2.0,
            priority_processing_service_tier: :priority,
            regions: ["us-east-1", "us-west-2"]
          }
        })
      ),
    {:xai, "grok-4.5"} =>
      Profile.new(
        Map.merge(@grok_profile, %{
          id: "grok-4.5",
          name: "Grok 4.5",
          release_date: "2026-07-08",
          last_updated: "2026-08-12",
          max_input_tokens: 500_000,
          max_output_tokens: 30_000,
          reasoning_effort_default: :high,
          reasoning_effort_levels: [:low, :medium, :high],
          extra: %{
            input_price_per_mtok: 2.00,
            cached_input_price_per_mtok: 0.30,
            output_price_per_mtok: 6.00,
            higher_context_pricing_threshold_tokens: 200_000,
            higher_context_input_price_per_mtok: 4.00,
            higher_context_cached_input_price_per_mtok: 0.60,
            higher_context_output_price_per_mtok: 12.00,
            cost_currency: "USD",
            pricing_source_url: "https://docs.x.ai/developers/pricing",
            pricing_modes: [:standard, :priority],
            priority_processing_price_multiplier: 2.0,
            priority_processing_service_tier: :priority,
            regions: ["us-east-1", "us-west-2"]
          }
        })
      ),
    {:xai, "grok-4.3"} =>
      Profile.new(
        Map.merge(@grok_profile, %{
          id: "grok-4.3",
          name: "Grok 4.3",
          release_date: "2026-05-01",
          last_updated: "2026-05-01",
          max_input_tokens: 1_000_000,
          max_output_tokens: 30_000,
          extra: @grok_4_20_extra
        })
      ),
    {:xai, "grok-4.20-0309-reasoning"} =>
      Profile.new(
        Map.merge(@grok_profile, %{
          id: "grok-4.20-0309-reasoning",
          name: "Grok 4.20 (Reasoning)",
          release_date: "2026-03-09",
          last_updated: "2026-03-09",
          max_input_tokens: 1_000_000,
          max_output_tokens: 30_000,
          extra: @grok_4_20_extra
        })
      ),
    {:xai, "grok-4.20-0309-non-reasoning"} =>
      Profile.new(
        Map.merge(@grok_profile, %{
          id: "grok-4.20-0309-non-reasoning",
          name: "Grok 4.20 (Non-Reasoning)",
          release_date: "2026-03-09",
          last_updated: "2026-03-09",
          max_input_tokens: 1_000_000,
          max_output_tokens: 30_000,
          reasoning_output: false,
          extra: @grok_4_20_extra
        })
      ),
    {:xai, "grok-build-0.1"} =>
      Profile.new(
        Map.merge(@grok_profile, %{
          id: "grok-build-0.1",
          name: "Grok Build 0.1",
          release_date: "2026-03-09",
          last_updated: "2026-03-09",
          max_input_tokens: 256_000,
          max_output_tokens: 30_000,
          extra: %{
            input_price_per_mtok: 1.00,
            cached_input_price_per_mtok: 0.20,
            output_price_per_mtok: 2.00,
            higher_context_pricing_threshold_tokens: 200_000,
            higher_context_input_price_per_mtok: 2.00,
            higher_context_cached_input_price_per_mtok: 0.40,
            higher_context_output_price_per_mtok: 4.00
          }
        })
      ),
    {:xai, "grok-4.20-multi-agent-0309"} =>
      Profile.new(
        Map.merge(@grok_profile, %{
          id: "grok-4.20-multi-agent-0309",
          name: "Grok 4.20 Multi-Agent Beta",
          release_date: "2026-03-09",
          last_updated: "2026-03-09",
          max_input_tokens: 1_000_000,
          max_output_tokens: 30_000,
          extra: @grok_4_20_extra
        })
      )
  }
  @profiles Map.new(@profiles, fn {key, profile} ->
              extra =
                Map.merge(profile.extra, %{
                  pricing_last_checked: "2026-10-19",
                  pricing_source_url: "https://docs.x.ai/developers/pricing",
                  higher_context_threshold_inclusive: true,
                  tool_pricing: %{
                    web_search: %{price_per_1000_calls: 5.0},
                    x_search: %{price_per_1000_posts: 5.0, price_per_1000_profiles: 10.0},
                    code_execution: %{price_per_1000_calls: 5.0},
                    attachment_search: %{price_per_1000_calls: 5.0},
                    collections_search: %{price_per_1000_calls: 2.5}
                  }
                })

              extra =
                if profile.id in ["grok-4.6", "grok-4.7"],
                  do: Map.put(extra, :regional_processing_multiplier, 1.1),
                  else: extra

              {key, %{profile | extra: extra}}
            end)
  def profiles, do: Map.values(@profiles)

  def resolve(model) do
    cond do
      metadata = @xai_deprecated_models[model] ->
        ProfileRegistry.deprecated_error(
          :xai,
          model,
          "xAI model is retired or redirected",
          Map.put(metadata, :retired_at, "2026-05-15T12:00:00-07:00")
        )

      reason = @xai_non_chat_models[model] ->
        {:error,
         Error.new(:unsupported_model, "xAI model is not a chat model", %{provider: :xai, model: model, reason: reason})}

      canonical_id = @xai_chat_aliases[model] ->
        ProfileRegistry.fetch_alias(@profiles, :xai, model, canonical_id)

      true ->
        ProfileRegistry.fetch_or_fallback(@profiles, :xai, model)
    end
  end
end
