defmodule BeamWeaver.Models.ProfileRegistry.Fallbacks do
  @moduledoc false

  alias BeamWeaver.Models.Profile
  alias BeamWeaver.Models.ProfileRegistry.Params

  def profile(:anthropic, "claude-" <> _rest = model) do
    high_output? = high_output_anthropic_model?(model)

    Profile.new(%{
      provider: :anthropic,
      id: model,
      name: "Claude family",
      max_input_tokens: if(high_output? or String.contains?(model, "sonnet-4-6"), do: 1_000_000, else: 200_000),
      max_output_tokens: if(high_output?, do: 128_000, else: 64_000),
      text_inputs: true,
      image_inputs: true,
      image_url_inputs: true,
      pdf_inputs: true,
      text_outputs: true,
      reasoning_output: true,
      tool_calling: true,
      tool_choice: true,
      parallel_tool_calls: true,
      structured_output: not String.match?(model, ~r/-\d{8}$/),
      streaming: true,
      usage_metadata: true,
      image_tool_message: true,
      pdf_tool_message: true,
      attachment: true,
      supported_params: Params.anthropic(),
      extra:
        if(adaptive_only_anthropic_model?(model),
          do: %{sampling_controls: :restricted, thinking_mode: :adaptive_only},
          else: %{}
        )
    })
  end

  def profile(:xai, "grok-" <> _rest = model) do
    Profile.new(%{
      provider: :xai,
      id: model,
      name: "Grok family",
      responses_api: true,
      chat_completions_api: true,
      max_input_tokens: 131_072,
      max_output_tokens: 4096,
      text_inputs: true,
      image_inputs: true,
      image_url_inputs: true,
      text_outputs: true,
      reasoning_output: String.contains?(model, ["reasoning", "mini", "4"]),
      tool_calling: true,
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
    })
  end

  def profile(:moonshot, "kimi-" <> _rest = model) do
    Profile.new(%{
      provider: :moonshot,
      id: model,
      name: "Kimi family",
      chat_completions_api: true,
      max_input_tokens: 262_144,
      text_inputs: true,
      image_inputs: true,
      image_url_inputs: true,
      video_inputs: true,
      text_outputs: true,
      reasoning_output: true,
      tool_calling: true,
      tool_choice: true,
      parallel_tool_calls: true,
      structured_output: true,
      streaming: true,
      usage_metadata: true,
      attachment: true,
      supported_params: Params.moonshot(),
      supported_params_by_api: %{chat_completions: Params.moonshot()},
      tokenizer: :o200k_base,
      extra: %{
        api_family: :chat_completions,
        family_fallback: true,
        openai_compatible: true,
        automatic_context_caching: true,
        partial_mode: true,
        built_in_tools: ["$web_search"]
      }
    })
  end

  def profile(:google, "gemini-" <> _rest = model) do
    Profile.new(%{
      provider: :google,
      id: model,
      name: "Gemini family",
      max_input_tokens: 1_048_576,
      max_output_tokens: 65_536,
      text_inputs: true,
      image_inputs: true,
      image_url_inputs: true,
      audio_inputs: true,
      video_inputs: true,
      pdf_inputs: true,
      text_outputs: true,
      reasoning_output: not String.contains?(model, "2.0"),
      tool_calling: true,
      tool_choice: true,
      parallel_tool_calls: true,
      structured_output: true,
      streaming: true,
      usage_metadata: true,
      image_tool_message: true,
      pdf_tool_message: true,
      attachment: true,
      supported_params: Params.google(),
      extra: %{
        api_family: :gemini_developer,
        built_in_tools: [
          :code_execution,
          :file_search,
          :google_maps,
          :google_search,
          :url_context
        ],
        unsupported_tools: [:computer_use],
        family_fallback: true,
        grounding_metadata: true,
        safety_settings: true
      }
    })
  end

  def profile(provider, model) do
    Profile.new(provider: provider, id: model, name: model, extra: %{unknown: true})
  end

  defp high_output_anthropic_model?(model) do
    opus_4_minor_at_least?(model, 6) or
      String.contains?(model, ["fable-5", "mythos-5"])
  end

  defp adaptive_only_anthropic_model?(model) do
    opus_4_minor_at_least?(model, 7) or
      String.contains?(model, ["fable-5", "mythos-5"])
  end

  defp opus_4_minor_at_least?(model, minimum) when is_binary(model) do
    case Regex.run(~r/opus-4-(\d+)/, model) do
      [_, minor] -> String.to_integer(minor) >= minimum
      _other -> false
    end
  end
end
