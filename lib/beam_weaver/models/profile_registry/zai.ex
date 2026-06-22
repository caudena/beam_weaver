defmodule BeamWeaver.Models.ProfileRegistry.ZAI do
  @moduledoc false

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Models.Profile
  alias BeamWeaver.Models.ProfileRegistry.Params

  @profile_last_updated "2026-06-23"

  @profile Profile.new(%{
             provider: :zai,
             id: "glm-5.2",
             name: "GLM-5.2",
             status: :active,
             last_updated: @profile_last_updated,
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
             supported_params_by_api: %{
               chat_completions: Params.zai()
             },
             tokenizer: nil,
             extra: %{
               api_family: :chat_completions,
               openai_compatible: true,
               json_mode_only: true,
               reasoning_efforts: [:max, :xhigh, :high, :medium, :low, :minimal, :none],
               thinking_modes: [:enabled, :disabled],
               tool_stream: true,
               x_log_id_header: "x-log-id",
               input_price_per_mtok: 1.40,
               cached_input_price_per_mtok: 0.26,
               output_price_per_mtok: 4.40,
               cost_currency: "USD"
             }
           })

  @profiles %{{:zai, "glm-5.2"} => @profile}

  def profiles_map, do: @profiles
  def profiles, do: Map.values(@profiles)

  def resolve("glm-5.2"), do: {:ok, @profile}

  def resolve(model) do
    {:error,
     Error.new(:unsupported_model, "Z.ai provider currently supports only GLM-5.2", %{
       provider: :zai,
       model: model,
       supported: ["glm-5.2"],
       expected: "zai:glm-5.2"
     })}
  end
end
