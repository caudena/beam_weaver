defmodule BeamWeaver.Models.ProfileRegistry.OpenAI do
  @moduledoc false

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Models.Profile
  alias BeamWeaver.Models.ProfileRegistry.Params

  @pricing_source_url "https://developers.openai.com/api/docs/pricing"

  @openai_5_6_specs [
    %{
      id: "gpt-5.6-sol",
      name: "GPT-5.6 Sol",
      input: 4.00,
      cached: 0.40,
      output: 20.00,
      extra: %{
        promotional_pricing_through: "2026-11-21",
        regular_input_price_per_mtok: 5.00,
        regular_cached_input_price_per_mtok: 0.50,
        regular_output_price_per_mtok: 30.00,
        higher_context_pricing_threshold_tokens: 272_000,
        higher_context_input_multiplier: 2.0,
        higher_context_output_multiplier: 1.5,
        regional_processing_multiplier: 1.1
      }
    },
    %{id: "gpt-5.6-terra", name: "GPT-5.6 Terra", input: 2.00, cached: 0.20, output: 12.00},
    %{id: "gpt-5.6-luna", name: "GPT-5.6 Luna", input: 0.20, cached: 0.02, output: 1.20}
  ]

  @openai_frontier_specs [
    %{
      id: "gpt-5.5",
      name: "GPT-5.5",
      max_input: 1_050_000,
      input: 5.00,
      cached: 0.50,
      output: 30.00,
      efforts: [:none, :low, :medium, :high, :xhigh],
      long_context: true
    },
    %{
      id: "gpt-5.5-pro",
      name: "GPT-5.5 Pro",
      max_input: 1_050_000,
      input: 30.00,
      output: 180.00,
      efforts: [:medium, :high, :xhigh],
      chat: false,
      streaming: false
    },
    %{
      id: "gpt-5.4",
      name: "GPT-5.4",
      max_input: 1_050_000,
      input: 2.50,
      cached: 0.25,
      output: 15.00,
      efforts: [:none, :low, :medium, :high, :xhigh],
      long_context: true
    },
    %{
      id: "gpt-5.4-pro",
      name: "GPT-5.4 Pro",
      max_input: 1_050_000,
      input: 30.00,
      output: 180.00,
      efforts: [:medium, :high, :xhigh],
      chat: false,
      structured_output: false,
      long_context: true
    },
    %{
      id: "gpt-5.4-mini",
      name: "GPT-5.4 mini",
      max_input: 400_000,
      input: 0.75,
      cached: 0.075,
      output: 4.50,
      efforts: [:none, :low, :medium, :high, :xhigh]
    },
    %{
      id: "gpt-5.4-nano",
      name: "GPT-5.4 nano",
      max_input: 400_000,
      input: 0.20,
      cached: 0.02,
      output: 1.25,
      efforts: [:none, :low, :medium, :high, :xhigh]
    },
    %{
      id: "gpt-5",
      name: "GPT-5",
      max_input: 400_000,
      input: 1.25,
      cached: 0.125,
      output: 10.00,
      efforts: [:minimal, :low, :medium, :high]
    },
    %{
      id: "gpt-5-mini",
      name: "GPT-5 mini",
      max_input: 400_000,
      input: 0.25,
      cached: 0.025,
      output: 2.00,
      efforts: [:minimal, :low, :medium, :high]
    },
    %{
      id: "gpt-5-nano",
      name: "GPT-5 nano",
      max_input: 400_000,
      input: 0.05,
      cached: 0.005,
      output: 0.40,
      efforts: [:minimal, :low, :medium, :high]
    },
    %{
      id: "gpt-4.1",
      name: "GPT-4.1",
      max_input: 1_047_576,
      max_output: 32_768,
      input: 2.00,
      cached: 0.50,
      output: 8.00,
      reasoning: false,
      efforts: []
    }
  ]

  @openai_frontier_ids MapSet.new(
                         Enum.map(@openai_5_6_specs, & &1.id) ++
                           Enum.map(@openai_frontier_specs, & &1.id)
                       )

  @openai_5_6_profiles Map.new(
                         @openai_5_6_specs,
                         fn spec ->
                           pricing = %{
                             input_price_per_mtok: spec.input,
                             cached_input_price_per_mtok: spec.cached,
                             cache_write_30m_price_per_mtok: spec.input * 1.25,
                             output_price_per_mtok: spec.output,
                             cost_currency: "USD",
                             pricing_source_url: @pricing_source_url
                           }

                           {{:openai, spec.id},
                            Profile.new(%{
                              provider: :openai,
                              id: spec.id,
                              name: spec.name,
                              status: :active,
                              release_date: "2026-07-09",
                              last_updated: "2026-08-27",
                              responses_api: true,
                              chat_completions_api: true,
                              tool_calling: true,
                              tool_call_streaming: true,
                              tool_choice: true,
                              parallel_tool_calls: true,
                              structured_output: true,
                              streaming: true,
                              usage_metadata: true,
                              supported_params: Params.responses(),
                              supported_params_by_api: %{
                                responses: Params.responses(),
                                chat_completions: Params.chat_completions()
                              },
                              max_input_tokens: 1_050_000,
                              max_output_tokens: 128_000,
                              image_inputs: true,
                              image_url_inputs: true,
                              image_tool_message: true,
                              audio_inputs: false,
                              reasoning_output: true,
                              tokenizer: :o200k_base,
                              extra:
                                Map.merge(
                                  %{
                                    frontier: true,
                                    pricing_modes: [:standard, :batch, :flex, :fast, :priority],
                                    batch_price_multiplier: 0.5,
                                    flex_price_multiplier: 0.5,
                                    fast_mode_price_multiplier: 2.0,
                                    fast_mode_service_tiers: [:fast, :priority],
                                    default_reasoning_effort: :medium,
                                    reasoning_efforts: [:none, :low, :medium, :high, :xhigh, :max],
                                    reasoning_modes: [:standard, :pro],
                                    persisted_reasoning_contexts: [:auto, :current_turn, :all_turns],
                                    prompt_cache_modes: [:implicit, :explicit],
                                    prompt_cache_ttl: "30m",
                                    prompt_cache_write_multiplier: 1.25,
                                    prompt_cache_read_discount_rate: 0.90,
                                    provider_capabilities: [
                                      :programmatic_tool_calling,
                                      :multi_agent_beta,
                                      :explicit_prompt_caching,
                                      :persisted_reasoning,
                                      :pro_reasoning_mode,
                                      :original_image_detail
                                    ]
                                  }
                                  |> Map.merge(pricing),
                                  Map.get(spec, :extra, %{})
                                )
                            })}
                         end
                       )

  @openai_frontier_profiles Map.new(
                              @openai_frontier_specs,
                              fn spec ->
                                chat? = Map.get(spec, :chat, true)
                                long_context? = Map.get(spec, :long_context, false)

                                pricing = %{
                                  input_price_per_mtok: spec.input,
                                  output_price_per_mtok: spec.output,
                                  cost_currency: "USD",
                                  pricing_source_url: @pricing_source_url,
                                  regional_processing_multiplier: 1.1,
                                  batch_price_multiplier: 0.5
                                }

                                pricing =
                                  if Map.has_key?(spec, :cached),
                                    do: Map.put(pricing, :cached_input_price_per_mtok, spec.cached),
                                    else: pricing

                                pricing =
                                  if long_context? do
                                    Map.merge(pricing, %{
                                      higher_context_pricing_threshold_tokens: 272_000,
                                      higher_context_input_multiplier: 2.0,
                                      higher_context_output_multiplier: 1.5
                                    })
                                  else
                                    pricing
                                  end

                                params_by_api =
                                  if chat? do
                                    %{
                                      responses: Params.responses(),
                                      chat_completions: Params.chat_completions()
                                    }
                                  else
                                    %{responses: Params.responses()}
                                  end

                                {{:openai, spec.id},
                                 Profile.new(%{
                                   provider: :openai,
                                   id: spec.id,
                                   name: spec.name,
                                   status: :active,
                                   last_updated: "2026-08-27",
                                   responses_api: true,
                                   chat_completions_api: chat?,
                                   tool_calling: true,
                                   tool_call_streaming: true,
                                   tool_choice: true,
                                   parallel_tool_calls: true,
                                   structured_output: Map.get(spec, :structured_output, true),
                                   streaming: Map.get(spec, :streaming, true),
                                   usage_metadata: true,
                                   supported_params: Params.responses(),
                                   supported_params_by_api: params_by_api,
                                   max_input_tokens: spec.max_input,
                                   max_output_tokens: Map.get(spec, :max_output, 128_000),
                                   image_inputs: true,
                                   image_url_inputs: true,
                                   image_tool_message: true,
                                   audio_inputs: false,
                                   reasoning_output: Map.get(spec, :reasoning, true),
                                   tokenizer: :o200k_base,
                                   extra:
                                     Map.merge(pricing, %{
                                       frontier: true,
                                       reasoning_efforts: spec.efforts
                                     })
                                 })}
                              end
                            )

  @openai_deprecated_models %{
    "gpt-5-chat-latest" => "gpt-5.5",
    "gpt-5-chat" => "gpt-5.5",
    "gpt-4.1-nano" => "gpt-5-nano",
    "gpt-4.5-preview" => "gpt-5.5",
    "gpt-4o-mini-search-preview" => "gpt-5.4-mini",
    "gpt-4o-search-preview" => "gpt-5.4",
    "gpt-4o-audio-preview" => "gpt-5.4",
    "gpt-4o-realtime-preview" => "gpt-5.4",
    "gpt-4-turbo" => "gpt-4.1",
    "gpt-4-turbo-preview" => "gpt-4.1",
    "gpt-4" => "gpt-4.1",
    "gpt-3.5-turbo" => "gpt-5.4-mini",
    "o4-mini" => "gpt-5-mini",
    "o3-mini" => "gpt-5-mini",
    "o1-pro" => "gpt-5.5-pro",
    "o1" => "gpt-5",
    "o1-mini" => "gpt-5-mini",
    "o1-preview" => "gpt-5",
    "text-embedding-ada-002" => "text-embedding-3-small"
  }

  @openai_chat_aliases %{
    "gpt-5.6" => "gpt-5.6-sol"
  }

  @openai_non_frontier_replacements %{
    "gpt-5.3-codex" => "gpt-5.5",
    "gpt-5.2-codex" => "gpt-5.5",
    "gpt-5.1-codex" => "gpt-5.5",
    "gpt-5.2-pro" => "gpt-5.5-pro",
    "gpt-5.1-pro" => "gpt-5.5-pro",
    "gpt-5-pro" => "gpt-5.5-pro",
    "gpt-5.2" => "gpt-5.5",
    "gpt-5.1" => "gpt-5.5",
    "gpt-4.1-mini" => "gpt-5.4-mini",
    "gpt-4o-mini" => "gpt-5.4-mini",
    "gpt-4o" => "gpt-5.4",
    "o3-pro" => "gpt-5.5-pro",
    "o3" => "gpt-5"
  }

  @profiles @openai_5_6_profiles
            |> Map.merge(@openai_frontier_profiles)
            |> Map.merge(%{
              {:openai, "text-embedding-3-small"} =>
                Profile.new(%{
                  provider: :openai,
                  id: "text-embedding-3-small",
                  name: "Text embedding 3 small",
                  supported_params: Params.embedding(),
                  max_input_tokens: 8_191,
                  tokenizer: :cl100k_base,
                  extra: %{
                    embedding_dimensions: 1536,
                    input_price_per_mtok: 0.02,
                    cost_currency: "USD",
                    pricing_source_url: @pricing_source_url
                  }
                }),
              {:openai, "text-embedding-3-large"} =>
                Profile.new(%{
                  provider: :openai,
                  id: "text-embedding-3-large",
                  name: "Text embedding 3 large",
                  supported_params: Params.embedding(),
                  max_input_tokens: 8_191,
                  tokenizer: :cl100k_base,
                  extra: %{
                    embedding_dimensions: 3072,
                    input_price_per_mtok: 0.13,
                    cost_currency: "USD",
                    pricing_source_url: @pricing_source_url
                  }
                })
            })
  def profiles_map, do: @profiles
  def profiles, do: Map.values(@profiles)
  def frontier_ids, do: @openai_frontier_ids

  def resolve(model) do
    cond do
      Map.has_key?(@openai_deprecated_models, model) ->
        deprecated_model_error(model)

      Map.has_key?(@openai_chat_aliases, model) ->
        alias_profile(model, Map.fetch!(@openai_chat_aliases, model))

      restricted_chat_model?(model) and not MapSet.member?(@openai_frontier_ids, model) ->
        non_frontier_model_error(model)

      true ->
        fetch_or_fallback(@profiles, :openai, model)
    end
  end

  defp deprecated_model_error(model) do
    replacement = Map.fetch!(@openai_deprecated_models, model)

    {:error,
     Error.new(:deprecated_model, "OpenAI model is deprecated", %{
       provider: :openai,
       model: model,
       replacement: replacement,
       expected: "openai:#{replacement}"
     })}
  end

  defp non_frontier_model_error(model) do
    replacement = Map.get(@openai_non_frontier_replacements, model, "gpt-5.5")

    {:error,
     Error.new(:unsupported_model, "OpenAI chat model is not in the supported frontier set", %{
       provider: :openai,
       model: model,
       replacement: replacement,
       expected: "openai:#{replacement}",
       supported: MapSet.to_list(@openai_frontier_ids) |> Enum.sort()
     })}
  end

  defp alias_profile(alias_id, canonical_id) do
    case Map.fetch(@profiles, {:openai, canonical_id}) do
      {:ok, profile} ->
        extra =
          profile.extra
          |> Map.put(:canonical_model, canonical_id)
          |> Map.put(:alias_model, alias_id)

        {:ok, %{profile | id: alias_id, name: "#{profile.name} (alias)", extra: extra}}

      :error ->
        {:fallback, :openai, alias_id}
    end
  end

  defp restricted_chat_model?("gpt-" <> _rest), do: true

  defp restricted_chat_model?(model) when is_binary(model) do
    String.match?(model, ~r/^o\d/)
  end

  defp restricted_chat_model?(_model), do: false

  defp fetch_or_fallback(profiles, provider, model) do
    case Map.fetch(profiles, {provider, model}) do
      {:ok, profile} -> {:ok, profile}
      :error -> {:fallback, provider, model}
    end
  end
end
