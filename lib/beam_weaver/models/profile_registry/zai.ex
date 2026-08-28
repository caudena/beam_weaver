defmodule BeamWeaver.Models.ProfileRegistry.ZAI do
  @moduledoc false

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Models.Profile
  alias BeamWeaver.Models.ProfileRegistry.Params

  @pricing_source_url "https://docs.z.ai/guides/overview/pricing"
  @supported_models ["glm-5.3", "glm-5.3-flash", "glm-5.2"]

  @common_profile %{
    status: :active,
    max_input_tokens: 1_000_000,
    max_output_tokens: 131_072,
    text_inputs: true,
    text_outputs: true,
    reasoning_output: true,
    tool_calling: true,
    tool_choice: true,
    parallel_tool_calls: true,
    structured_output: true,
    streaming: true,
    usage_metadata: true,
    chat_completions_api: true,
    supported_params: Params.zai(),
    supported_params_by_api: %{chat_completions: Params.zai()},
    tokenizer: nil
  }

  @common_extra %{
    api_family: :chat_completions,
    openai_compatible: true,
    json_mode_only: true,
    tool_stream: true,
    x_log_id_header: "x-log-id",
    cost_currency: "USD",
    pricing_source_url: @pricing_source_url
  }

  @glm_5_3 Profile.new(
             Map.merge(@common_profile, %{
               provider: :zai,
               id: "glm-5.3",
               name: "GLM-5.3",
               release_date: "2026-08-18",
               last_updated: "2026-08-27",
               extra:
                 Map.merge(@common_extra, %{
                   reasoning_efforts: [:low, :high, :max],
                   default_reasoning_effort: :max,
                   thinking_modes: [:enabled],
                   input_price_per_mtok: 1.40,
                   cached_input_price_per_mtok: 0.26,
                   output_price_per_mtok: 4.40
                 })
             })
           )

  @glm_5_3_flash Profile.new(
                   Map.merge(@common_profile, %{
                     provider: :zai,
                     id: "glm-5.3-flash",
                     name: "GLM-5.3-Flash",
                     release_date: "2026-08-26",
                     last_updated: "2026-08-27",
                     image_inputs: true,
                     image_url_inputs: true,
                     video_inputs: true,
                     pdf_inputs: true,
                     attachment: true,
                     extra:
                       Map.merge(@common_extra, %{
                         reasoning_efforts: [:low, :high, :max],
                         default_reasoning_effort: :max,
                         thinking_modes: [:enabled],
                         native_multimodal: true,
                         input_price_per_mtok: 0.075,
                         cached_input_price_per_mtok: 0.015,
                         output_price_per_mtok: 0.25,
                         promotional_pricing_through: "2026-09-09T24:00:00+08:00",
                         regular_input_price_per_mtok: 0.15,
                         regular_cached_input_price_per_mtok: 0.03,
                         regular_output_price_per_mtok: 0.50
                       })
                   })
                 )

  @glm_5_2 Profile.new(
             Map.merge(@common_profile, %{
               provider: :zai,
               id: "glm-5.2",
               name: "GLM-5.2",
               release_date: "2026-06-16",
               last_updated: "2026-08-27",
               extra:
                 Map.merge(@common_extra, %{
                   reasoning_efforts: [:max, :xhigh, :high, :medium, :low, :minimal, :none],
                   thinking_modes: [:enabled, :disabled],
                   input_price_per_mtok: 1.40,
                   cached_input_price_per_mtok: 0.26,
                   output_price_per_mtok: 4.40
                 })
             })
           )

  @profiles %{
    {:zai, "glm-5.3"} => @glm_5_3,
    {:zai, "glm-5.3-flash"} => @glm_5_3_flash,
    {:zai, "glm-5.2"} => @glm_5_2
  }

  def profiles_map, do: @profiles
  def profiles, do: Map.values(@profiles)

  def resolve(model) do
    case Map.fetch(@profiles, {:zai, model}) do
      {:ok, profile} ->
        {:ok, profile}

      :error ->
        {:error,
         Error.new(:unsupported_model, "Z.ai model is not supported", %{
           provider: :zai,
           model: model,
           supported: @supported_models,
           expected: "zai:glm-5.3"
         })}
    end
  end
end
