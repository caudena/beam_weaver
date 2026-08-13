defmodule BeamWeaver.Models.ProfileRegistry.DeepSeek do
  @moduledoc false

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Models.Profile
  alias BeamWeaver.Models.ProfileRegistry.Params

  @supported_models ["deepseek-v4-flash", "deepseek-v4-pro"]

  @retired_models ["deepseek-chat", "deepseek-reasoner"]

  @common_profile %{
    status: :active,
    release_date: "2026-04-24",
    last_updated: "2026-08-13",
    max_input_tokens: 1_048_576,
    max_output_tokens: 393_216,
    text_inputs: true,
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
    tokenizer: nil
  }

  @flash Profile.new(
           Map.merge(@common_profile, %{
             provider: :deepseek,
             id: "deepseek-v4-flash",
             name: "DeepSeek V4 Flash",
             release_date: "2026-07-31",
             responses_api: true,
             supported_params: Params.deepseek_chat_completions(),
             supported_params_by_api: %{
               chat_completions: Params.deepseek_chat_completions(),
               responses: Params.deepseek_responses()
             },
             extra: %{
               api_families: [:chat_completions, :responses],
               openai_compatible: true,
               model_version: "DeepSeek-V4-Flash-0731",
               thinking_modes: [:enabled, :disabled],
               default_thinking_mode: :enabled,
               reasoning_efforts: [:low, :high, :max],
               compatibility_reasoning_efforts: %{minimal: :low, medium: :high, xhigh: :high},
               chat_prefix_completion: :beta,
               fim_completion: %{status: :beta, thinking: :disabled},
               strict_tool_calls: :beta,
               automatic_context_caching: true,
               concurrency_limit: 2_500,
               input_price_per_mtok: 0.22,
               cached_input_price_per_mtok: 0.007,
               output_price_per_mtok: 0.66,
               cost_currency: "USD",
               pricing_source_url: "https://api-docs.deepseek.com/quick_start/pricing/",
               pricing_last_checked: "2026-08-13",
               time_based_pricing: %{
                 timezone: "UTC",
                 default_mode: :off_peak,
                 peak_windows: [
                   %{start_minute: 60, end_minute: 240},
                   %{start_minute: 360, end_minute: 600}
                 ],
                 off_peak: %{
                   input_price_per_mtok: 0.22,
                   cached_input_price_per_mtok: 0.007,
                   output_price_per_mtok: 0.66
                 },
                 peak: %{
                   input_price_per_mtok: 0.44,
                   cached_input_price_per_mtok: 0.014,
                   output_price_per_mtok: 1.32
                 }
               }
             }
           })
         )

  @pro Profile.new(
         Map.merge(@common_profile, %{
           provider: :deepseek,
           id: "deepseek-v4-pro",
           name: "DeepSeek V4 Pro",
           release_date: "2026-08-13",
           responses_api: true,
           supported_params: Params.deepseek_chat_completions(),
           supported_params_by_api: %{
             chat_completions: Params.deepseek_chat_completions(),
             responses: Params.deepseek_responses()
           },
           extra: %{
             api_families: [:chat_completions, :responses],
             openai_compatible: true,
             model_version: "DeepSeek-V4-Pro-0813",
             thinking_modes: [:enabled, :disabled],
             default_thinking_mode: :enabled,
             reasoning_efforts: [:low, :high, :max],
             compatibility_reasoning_efforts: %{minimal: :low, medium: :high, xhigh: :high},
             chat_prefix_completion: :beta,
             fim_completion: %{status: :beta, thinking: :disabled},
             strict_tool_calls: :beta,
             automatic_context_caching: true,
             concurrency_limit: 500,
             input_price_per_mtok: 0.66,
             cached_input_price_per_mtok: 0.022,
             output_price_per_mtok: 1.98,
             cost_currency: "USD",
             pricing_source_url: "https://api-docs.deepseek.com/quick_start/pricing/",
             pricing_last_checked: "2026-08-13",
             time_based_pricing: %{
               timezone: "UTC",
               default_mode: :off_peak,
               peak_windows: [
                 %{start_minute: 60, end_minute: 240},
                 %{start_minute: 360, end_minute: 600}
               ],
               off_peak: %{
                 input_price_per_mtok: 0.66,
                 cached_input_price_per_mtok: 0.022,
                 output_price_per_mtok: 1.98
               },
               peak: %{
                 input_price_per_mtok: 1.32,
                 cached_input_price_per_mtok: 0.044,
                 output_price_per_mtok: 3.96
               }
             }
           }
         })
       )

  @profiles %{
    {:deepseek, "deepseek-v4-flash"} => @flash,
    {:deepseek, "deepseek-v4-pro"} => @pro
  }

  def profiles_map, do: @profiles
  def profiles, do: Map.values(@profiles)

  def resolve(model) when is_binary(model) do
    cond do
      model in @retired_models ->
        retired_model_error(model)

      profile = Map.get(@profiles, {:deepseek, model}) ->
        {:ok, profile}

      true ->
        unsupported_model_error(model)
    end
  end

  defp retired_model_error(model) do
    {:error,
     Error.new(:deprecated_model, "DeepSeek model identifier has been retired", %{
       provider: :deepseek,
       model: model,
       retired_at: "2026-07-24T15:59:00Z",
       supported: @supported_models,
       expected: "deepseek:deepseek-v4-flash"
     })}
  end

  defp unsupported_model_error(model) do
    {:error,
     Error.new(:unsupported_model, "DeepSeek model is not supported", %{
       provider: :deepseek,
       model: model,
       supported: @supported_models,
       expected: "deepseek:deepseek-v4-flash"
     })}
  end
end
