defmodule BeamWeaver.Models.ProfileRegistry.DeepSeek do
  @moduledoc false

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Models.Profile
  alias BeamWeaver.Models.ProfileRegistry.Params

  @supported_models ["deepseek-flash", "deepseek-v4-flash", "deepseek-v4-flash-vision-exp", "deepseek-v4-pro"]
  @vision_models ["deepseek-flash", "deepseek-v4-flash", "deepseek-v4-flash-vision-exp"]
  @retired_models ["deepseek-chat", "deepseek-reasoner"]
  @pricing_source "https://api-docs.deepseek.com/quick_start/pricing/"
  @peak_schedule %{
    timezone: "UTC",
    default_mode: :off_peak,
    peak_iso_weekdays: [1, 2, 3, 4, 5],
    peak_windows: [%{start_minute: 60, end_minute: 240}, %{start_minute: 360, end_minute: 600}]
  }
  @old_flash_rates %{input_price_per_mtok: 0.22, cached_input_price_per_mtok: 0.007, output_price_per_mtok: 0.66}
  @flash_rates %{input_price_per_mtok: 0.15, cached_input_price_per_mtok: 0.003, output_price_per_mtok: 0.6}
  @pro_rates %{input_price_per_mtok: 0.66, cached_input_price_per_mtok: 0.022, output_price_per_mtok: 1.98}
  @old_flash_pricing Map.put(
                       @old_flash_rates,
                       :time_based_pricing,
                       Map.merge(@peak_schedule, %{
                         off_peak: @old_flash_rates,
                         peak: %{
                           input_price_per_mtok: 0.44,
                           cached_input_price_per_mtok: 0.014,
                           output_price_per_mtok: 1.32
                         }
                       })
                     )
  @flash_pricing Map.put(
                   @flash_rates,
                   :time_based_pricing,
                   Map.merge(@peak_schedule, %{
                     off_peak: @flash_rates,
                     peak: %{input_price_per_mtok: 0.3, cached_input_price_per_mtok: 0.006, output_price_per_mtok: 1.2}
                   })
                 )
  @pro_pricing Map.put(
                 @pro_rates,
                 :time_based_pricing,
                 Map.merge(@peak_schedule, %{
                   off_peak: @pro_rates,
                   peak: %{input_price_per_mtok: 1.32, cached_input_price_per_mtok: 0.044, output_price_per_mtok: 3.96}
                 })
               )
  @flash_history [
    Map.put(@old_flash_pricing, :effective_at, nil),
    Map.put(@flash_pricing, :effective_at, "2026-09-10T04:00:00Z")
  ]
  @common_extra %{
    api_families: [:chat_completions, :responses],
    openai_compatible: true,
    thinking_modes: [:enabled, :disabled],
    default_thinking_mode: :enabled,
    reasoning_efforts: [:low, :high, :max],
    compatibility_reasoning_efforts: %{minimal: :low, medium: :high, xhigh: :high, ultra: :max},
    chat_prefix_completion: :beta,
    fim_completion: %{status: :beta, thinking: :disabled},
    strict_tool_calls: :beta,
    automatic_context_caching: true,
    cost_currency: "USD",
    pricing_source_url: @pricing_source,
    pricing_last_checked: "2026-09-10"
  }
  @common_profile %{
    provider: :deepseek,
    status: :active,
    last_updated: "2026-09-10",
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
    responses_api: true,
    supported_params: Params.deepseek_chat_completions(),
    supported_params_by_api: %{
      chat_completions: Params.deepseek_chat_completions(),
      responses: Params.deepseek_responses()
    }
  }
  @flash Profile.new(
           Map.merge(@common_profile, %{
             id: "deepseek-flash",
             name: "DeepSeek V4.1 Flash",
             release_date: "2026-09-10",
             image_inputs: true,
             image_url_inputs: true,
             image_tool_message: true,
             attachment: true,
             extra:
               @common_extra
               |> Map.merge(@flash_pricing)
               |> Map.merge(%{
                 model_version: "DeepSeek-V4.1-Flash",
                 concurrency_limit: 2_500,
                 supported_image_formats: [:jpeg, :png, :gif, :webp],
                 max_images_per_request: 600,
                 max_inline_image_bytes: 33_554_432,
                 max_image_file_bytes: 67_108_864,
                 max_image_request_bytes: 50_331_648,
                 image_detail_levels: [:low, :high, :original, :auto],
                 image_input_roles: %{chat_completions: [:user, :tool], responses: [:user, :developer, :tool]},
                 pricing_effective_at: "2026-09-10T04:00:00Z"
               })
           })
         )
  @pro Profile.new(
         Map.merge(@common_profile, %{
           id: "deepseek-v4-pro",
           name: "DeepSeek V4 Pro",
           release_date: "2026-08-13",
           extra:
             @common_extra
             |> Map.merge(@pro_pricing)
             |> Map.merge(%{
               model_version: "DeepSeek-V4-Pro-0813",
               concurrency_limit: 500,
               scheduled_redirect: %{model: "deepseek-flash", at: "2026-09-14T04:00:00Z"},
               pricing_history: [
                 Map.put(@pro_pricing, :effective_at, nil),
                 Map.put(@flash_pricing, :effective_at, "2026-09-14T04:00:00Z")
               ]
             })
         })
       )
  @profiles %{
    {:deepseek, "deepseek-flash"} => @flash,
    {:deepseek, "deepseek-v4-flash"} => %{
      @flash
      | id: "deepseek-v4-flash",
        extra:
          Map.merge(@flash.extra, %{
            canonical_model: "deepseek-flash",
            compatibility_alias: true,
            pricing_history: @flash_history
          })
    },
    {:deepseek, "deepseek-v4-flash-vision-exp"} => %{
      @flash
      | id: "deepseek-v4-flash-vision-exp",
        extra:
          Map.merge(@flash.extra, %{
            canonical_model: "deepseek-flash",
            compatibility_alias: true,
            pricing_history: @flash_history
          })
    },
    {:deepseek, "deepseek-v4-pro"} => @pro
  }

  def supported_models, do: @supported_models
  def vision_model?(model), do: model in @vision_models
  def profiles_map, do: @profiles
  def profiles, do: Map.values(@profiles)

  def resolve(model) when is_binary(model) do
    cond do
      model in @retired_models -> retired_model_error(model)
      profile = Map.get(@profiles, {:deepseek, model}) -> {:ok, profile}
      true -> unsupported_model_error(model)
    end
  end

  defp retired_model_error(model) do
    {:error,
     Error.new(:deprecated_model, "DeepSeek model identifier has been retired", %{
       provider: :deepseek,
       model: model,
       retired_at: "2026-07-24T15:59:00Z",
       supported: @supported_models,
       expected: "deepseek:deepseek-flash"
     })}
  end

  defp unsupported_model_error(model) do
    {:error,
     Error.new(:unsupported_model, "DeepSeek model is not supported", %{
       provider: :deepseek,
       model: model,
       supported: @supported_models,
       expected: "deepseek:deepseek-flash"
     })}
  end
end
