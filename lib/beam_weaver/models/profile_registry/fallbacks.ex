defmodule BeamWeaver.Models.ProfileRegistry.Fallbacks do
  @moduledoc false

  alias BeamWeaver.Models.Profile
  alias BeamWeaver.Models.ProfileRegistry.Params

  def profile(:openai, "gpt-5" <> _rest = model) do
    max_input_tokens =
      if model == "gpt-5" do
        272_000
      else
        400_000
      end

    openai_chat_family(model, "GPT-5 family",
      max_input_tokens: max_input_tokens,
      max_output_tokens: 128_000,
      reasoning_output: true,
      tokenizer: :o200k_base
    )
  end

  def profile(:openai, "gpt-4.1" <> _rest = model) do
    openai_chat_family(model, "GPT-4.1 family",
      max_input_tokens: 1_000_000,
      max_output_tokens: 32_768,
      tokenizer: :o200k_base
    )
  end

  def profile(:anthropic, "claude-" <> _rest = model) do
    anthropic_chat_family(model, "Claude family",
      max_input_tokens: anthropic_max_input_tokens(model),
      max_output_tokens: anthropic_max_output_tokens(model),
      structured_output: not String.match?(model, ~r/-\d{8}$/),
      extra: anthropic_extra(model)
    )
  end

  def profile(:xai, "grok-" <> _rest = model) do
    xai_chat_family(model, "Grok family",
      max_input_tokens: 131_072,
      max_output_tokens: 4096,
      reasoning_output: String.contains?(model, ["reasoning", "mini", "4"])
    )
  end

  def profile(:moonshot, "kimi-" <> _rest = model) do
    moonshot_chat_family(model, "Kimi family",
      max_input_tokens: 262_144,
      max_output_tokens: nil,
      reasoning_output: true
    )
  end

  def profile(:google, "gemini-" <> _rest = model) do
    google_chat_family(model, "Gemini family",
      max_input_tokens: 1_048_576,
      max_output_tokens: 65_536,
      reasoning_output: not String.contains?(model, "2.0")
    )
  end

  def profile(provider, model) do
    Profile.new(provider: provider, id: model, name: model, extra: %{unknown: true})
  end

  defp openai_chat_family(model, name, opts) do
    opts = Map.new(opts)

    Profile.new(%{
      provider: :openai,
      id: model,
      name: name,
      responses_api: true,
      chat_completions_api: true,
      tool_calling: true,
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
      max_input_tokens: Map.get(opts, :max_input_tokens),
      max_output_tokens: Map.get(opts, :max_output_tokens),
      image_inputs: true,
      image_url_inputs: true,
      audio_inputs: true,
      reasoning_output: Map.get(opts, :reasoning_output, false),
      tokenizer: Map.get(opts, :tokenizer, :o200k_base)
    })
  end

  defp anthropic_chat_family(model, name, opts) do
    opts = Map.new(opts)

    Profile.new(%{
      provider: :anthropic,
      id: model,
      name: name,
      max_input_tokens: Map.get(opts, :max_input_tokens, 200_000),
      max_output_tokens: Map.get(opts, :max_output_tokens, 64_000),
      text_inputs: true,
      image_inputs: true,
      image_url_inputs: true,
      pdf_inputs: true,
      text_outputs: true,
      reasoning_output: true,
      tool_calling: true,
      tool_choice: true,
      parallel_tool_calls: true,
      structured_output: Map.get(opts, :structured_output, true),
      streaming: true,
      usage_metadata: true,
      image_tool_message: true,
      pdf_tool_message: true,
      attachment: true,
      supported_params: Params.anthropic(),
      extra: Map.get(opts, :extra, %{})
    })
  end

  defp anthropic_max_input_tokens(model) do
    if opus_4_minor_at_least?(model, 6) or String.contains?(model, "sonnet-4-6") do
      1_000_000
    else
      200_000
    end
  end

  defp anthropic_max_output_tokens(model) do
    if opus_4_minor_at_least?(model, 6), do: 128_000, else: 64_000
  end

  defp anthropic_extra(model) do
    if opus_4_minor_at_least?(model, 7) do
      %{sampling_controls: :restricted, thinking_mode: :adaptive_only}
    else
      %{}
    end
  end

  defp opus_4_minor_at_least?(model, minimum) when is_binary(model) do
    case Regex.run(~r/opus-4-(\d+)/, model) do
      [_, minor] -> String.to_integer(minor) >= minimum
      _other -> false
    end
  end

  defp xai_chat_family(model, name, opts) do
    opts = Map.new(opts)

    Profile.new(%{
      provider: :xai,
      id: model,
      name: name,
      responses_api: true,
      chat_completions_api: true,
      max_input_tokens: Map.get(opts, :max_input_tokens, 131_072),
      max_output_tokens: Map.get(opts, :max_output_tokens, 4096),
      text_inputs: true,
      image_inputs: true,
      image_url_inputs: true,
      text_outputs: true,
      reasoning_output: Map.get(opts, :reasoning_output, false),
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

  defp moonshot_chat_family(model, name, opts) do
    opts = Map.new(opts)

    Profile.new(%{
      provider: :moonshot,
      id: model,
      name: name,
      chat_completions_api: true,
      max_input_tokens: Map.get(opts, :max_input_tokens, 262_144),
      max_output_tokens: Map.get(opts, :max_output_tokens),
      text_inputs: true,
      image_inputs: true,
      image_url_inputs: true,
      video_inputs: true,
      text_outputs: true,
      reasoning_output: Map.get(opts, :reasoning_output, true),
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

  defp google_chat_family(model, name, opts) do
    opts = Map.new(opts)

    Profile.new(%{
      provider: :google,
      id: model,
      name: name,
      max_input_tokens: Map.get(opts, :max_input_tokens, 1_048_576),
      max_output_tokens: Map.get(opts, :max_output_tokens, 65_536),
      text_inputs: true,
      image_inputs: true,
      image_url_inputs: true,
      audio_inputs: true,
      video_inputs: true,
      pdf_inputs: true,
      text_outputs: true,
      reasoning_output: Map.get(opts, :reasoning_output, true),
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
end
