defmodule BeamWeaver.Models.ProfileRegistry.Moonshot do
  @moduledoc false

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Models.Profile
  alias BeamWeaver.Models.ProfileRegistry.Params

  @moonshot_deprecated_models %{
    "kimi-latest" => %{
      replacement: "kimi-k2.6",
      discontinued_at: "2026-01-28"
    },
    "kimi-thinking-preview" => %{
      replacement: "kimi-k2.6",
      discontinued_at: "2025-11-11"
    },
    "kimi-k2-0905-preview" => %{
      replacement: "kimi-k2.6",
      discontinued_at: "2026-05-25"
    },
    "kimi-k2-0711-preview" => %{
      replacement: "kimi-k2.6",
      discontinued_at: "2026-05-25"
    },
    "kimi-k2-turbo-preview" => %{
      replacement: "kimi-k2.6",
      discontinued_at: "2026-05-25"
    },
    "kimi-k2-thinking" => %{
      replacement: "kimi-k2.6",
      discontinued_at: "2026-05-25"
    },
    "kimi-k2-thinking-turbo" => %{
      replacement: "kimi-k2.6",
      discontinued_at: "2026-05-25"
    }
  }

  @profiles %{
    {:moonshot, "kimi-k2.6"} =>
      Profile.new(%{
        provider: :moonshot,
        id: "kimi-k2.6",
        name: "Kimi K2.6",
        status: :active,
        release_date: "2026-05-25",
        last_updated: "2026-05-25",
        max_input_tokens: 262_144,
        max_output_tokens: nil,
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
        chat_completions_api: true,
        attachment: true,
        supported_params: Params.moonshot(),
        supported_params_by_api: %{
          chat_completions: Params.moonshot()
        },
        tokenizer: :o200k_base,
        extra: %{
          api_family: :chat_completions,
          openai_compatible: true,
          automatic_context_caching: true,
          partial_mode: true,
          built_in_tools: ["$web_search"],
          unsupported_api_families: [:responses, :embeddings, :batch, :files],
          sampling_controls: :fixed,
          input_cache_hit_price_per_mtok: 0.16,
          input_cache_miss_price_per_mtok: 0.95,
          output_price_per_mtok: 4.00,
          batch_input_cache_hit_price_per_mtok: 0.10,
          batch_input_cache_miss_price_per_mtok: 0.57,
          batch_output_price_per_mtok: 2.40
        }
      })
  }
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
