defmodule BeamWeaver.Models.ProfileRegistry.Anthropic do
  @moduledoc false

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Models.Profile
  alias BeamWeaver.Models.ProfileRegistry.Params

  @anthropic_deprecated_models %{
    "claude-opus-4" => %{
      replacement: "claude-opus-4-8",
      deprecated_at: "2026-04-14",
      retirement_date: "2026-06-15"
    },
    "claude-opus-4-0" => %{
      replacement: "claude-opus-4-8",
      deprecated_at: "2026-04-14",
      retirement_date: "2026-06-15"
    },
    "claude-opus-4-20250514" => %{
      replacement: "claude-opus-4-8",
      deprecated_at: "2026-04-14",
      retirement_date: "2026-06-15"
    },
    "claude-sonnet-4" => %{
      replacement: "claude-sonnet-4-6",
      deprecated_at: "2026-04-14",
      retirement_date: "2026-06-15"
    },
    "claude-sonnet-4-0" => %{
      replacement: "claude-sonnet-4-6",
      deprecated_at: "2026-04-14",
      retirement_date: "2026-06-15"
    },
    "claude-sonnet-4-20250514" => %{
      replacement: "claude-sonnet-4-6",
      deprecated_at: "2026-04-14",
      retirement_date: "2026-06-15"
    }
  }

  @anthropic_retired_models %{
    "claude-3-7-sonnet-20250219" => %{
      replacement: "claude-sonnet-4-6",
      retirement_date: "2026-02-19"
    },
    "claude-3-5-sonnet-20240620" => %{
      replacement: "claude-sonnet-4-6",
      retirement_date: "2025-10-28"
    },
    "claude-3-5-sonnet-20241022" => %{
      replacement: "claude-sonnet-4-6",
      retirement_date: "2025-10-28"
    },
    "claude-3-sonnet-20240229" => %{
      replacement: "claude-sonnet-4-6",
      retirement_date: "2025-07-21"
    },
    "claude-3-opus-20240229" => %{
      replacement: "claude-opus-4-8",
      retirement_date: "2026-01-05"
    },
    "claude-3-5-haiku-20241022" => %{
      replacement: "claude-haiku-4-5-20251001",
      retirement_date: "2026-02-19"
    },
    "claude-3-haiku-20240307" => %{
      replacement: "claude-haiku-4-5-20251001",
      retirement_date: "2026-04-20"
    },
    "claude-2.0" => %{replacement: "claude-opus-4-8", retirement_date: "2025-07-21"},
    "claude-2.1" => %{replacement: "claude-opus-4-8", retirement_date: "2025-07-21"},
    "claude-1.0" => %{
      replacement: "claude-haiku-4-5-20251001",
      retirement_date: "2024-11-06"
    },
    "claude-1.1" => %{
      replacement: "claude-haiku-4-5-20251001",
      retirement_date: "2024-11-06"
    },
    "claude-1.2" => %{
      replacement: "claude-haiku-4-5-20251001",
      retirement_date: "2024-11-06"
    },
    "claude-1.3" => %{
      replacement: "claude-haiku-4-5-20251001",
      retirement_date: "2024-11-06"
    },
    "claude-instant-1.0" => %{
      replacement: "claude-haiku-4-5-20251001",
      retirement_date: "2024-11-06"
    },
    "claude-instant-1.1" => %{
      replacement: "claude-haiku-4-5-20251001",
      retirement_date: "2024-11-06"
    },
    "claude-instant-1.2" => %{
      replacement: "claude-haiku-4-5-20251001",
      retirement_date: "2024-11-06"
    }
  }

  @profiles %{
    {:anthropic, "claude-fable-5"} =>
      Profile.new(%{
        provider: :anthropic,
        id: "claude-fable-5",
        name: "Claude Fable 5",
        status: :active,
        release_date: "2026-06-09",
        last_updated: "2026-06-09",
        max_input_tokens: 1_000_000,
        max_output_tokens: 128_000,
        text_inputs: true,
        image_inputs: true,
        image_url_inputs: true,
        pdf_inputs: true,
        text_outputs: true,
        reasoning_output: true,
        tool_calling: true,
        tool_choice: true,
        parallel_tool_calls: true,
        structured_output: true,
        streaming: true,
        usage_metadata: true,
        image_tool_message: true,
        pdf_tool_message: true,
        attachment: true,
        supported_params: Params.anthropic(),
        extra: %{
          cache_read_price_per_mtok: 1.00,
          cache_write_5m_price_per_mtok: 12.50,
          cache_write_1h_price_per_mtok: 20.00,
          input_price_per_mtok: 10.00,
          output_price_per_mtok: 50.00,
          batch_input_price_per_mtok: 5.00,
          batch_output_price_per_mtok: 25.00,
          inference_geo_us_multiplier: 1.1,
          prompt_cache_min_tokens: 1024,
          retirement_not_before: "2027-06-09",
          sampling_controls: :restricted,
          thinking_mode: :adaptive_only
        }
      }),
    {:anthropic, "claude-mythos-5"} =>
      Profile.new(%{
        provider: :anthropic,
        id: "claude-mythos-5",
        name: "Claude Mythos 5",
        status: :active,
        release_date: "2026-06-09",
        last_updated: "2026-06-09",
        max_input_tokens: 1_000_000,
        max_output_tokens: 128_000,
        text_inputs: true,
        image_inputs: true,
        image_url_inputs: true,
        pdf_inputs: true,
        text_outputs: true,
        reasoning_output: true,
        tool_calling: true,
        tool_choice: true,
        parallel_tool_calls: true,
        structured_output: true,
        streaming: true,
        usage_metadata: true,
        image_tool_message: true,
        pdf_tool_message: true,
        attachment: true,
        supported_params: Params.anthropic(),
        extra: %{
          cache_read_price_per_mtok: 1.00,
          cache_write_5m_price_per_mtok: 12.50,
          cache_write_1h_price_per_mtok: 20.00,
          input_price_per_mtok: 10.00,
          output_price_per_mtok: 50.00,
          batch_input_price_per_mtok: 5.00,
          batch_output_price_per_mtok: 25.00,
          inference_geo_us_multiplier: 1.1,
          prompt_cache_min_tokens: 1024,
          retirement_not_before: "2027-06-09",
          sampling_controls: :restricted,
          thinking_mode: :adaptive_only
        }
      }),
    {:anthropic, "claude-opus-4-8"} =>
      Profile.new(%{
        provider: :anthropic,
        id: "claude-opus-4-8",
        name: "Claude Opus 4.8",
        status: :active,
        release_date: "2026-05-28",
        last_updated: "2026-05-28",
        max_input_tokens: 1_000_000,
        max_output_tokens: 128_000,
        text_inputs: true,
        image_inputs: true,
        image_url_inputs: true,
        pdf_inputs: true,
        text_outputs: true,
        reasoning_output: true,
        tool_calling: true,
        tool_choice: true,
        parallel_tool_calls: true,
        structured_output: true,
        streaming: true,
        usage_metadata: true,
        image_tool_message: true,
        pdf_tool_message: true,
        attachment: true,
        supported_params: Params.anthropic(),
        extra: %{
          cache_read_price_per_mtok: 0.50,
          cache_write_5m_price_per_mtok: 6.25,
          cache_write_1h_price_per_mtok: 10.00,
          input_price_per_mtok: 5.00,
          output_price_per_mtok: 25.00,
          batch_input_price_per_mtok: 2.50,
          batch_output_price_per_mtok: 12.50,
          default_effort: :high,
          fast_mode_price_multiplier: 6,
          inference_geo_us_multiplier: 1.1,
          prompt_cache_min_tokens: 1024,
          retirement_not_before: "2027-05-28",
          sampling_controls: :restricted,
          thinking_mode: :adaptive_only
        }
      }),
    {:anthropic, "claude-opus-4-7"} =>
      Profile.new(%{
        provider: :anthropic,
        id: "claude-opus-4-7",
        name: "Claude Opus 4.7",
        status: :active,
        release_date: "2026-04-16",
        last_updated: "2026-04-16",
        max_input_tokens: 1_000_000,
        max_output_tokens: 128_000,
        text_inputs: true,
        image_inputs: true,
        image_url_inputs: true,
        pdf_inputs: true,
        text_outputs: true,
        reasoning_output: true,
        tool_calling: true,
        tool_choice: true,
        parallel_tool_calls: true,
        structured_output: true,
        streaming: true,
        usage_metadata: true,
        image_tool_message: true,
        pdf_tool_message: true,
        attachment: true,
        supported_params: Params.anthropic(),
        extra: %{
          cache_read_price_per_mtok: 0.50,
          cache_write_5m_price_per_mtok: 6.25,
          cache_write_1h_price_per_mtok: 10.00,
          input_price_per_mtok: 5.00,
          output_price_per_mtok: 25.00,
          batch_input_price_per_mtok: 2.50,
          batch_output_price_per_mtok: 12.50,
          fast_mode_price_multiplier: 6,
          retirement_not_before: "2027-04-16",
          sampling_controls: :restricted,
          thinking_mode: :adaptive_only
        }
      }),
    {:anthropic, "claude-opus-4-6"} =>
      Profile.new(%{
        provider: :anthropic,
        id: "claude-opus-4-6",
        name: "Claude Opus 4.6",
        status: :active,
        release_date: "2026-02-05",
        last_updated: "2026-02-05",
        max_input_tokens: 1_000_000,
        max_output_tokens: 128_000,
        text_inputs: true,
        image_inputs: true,
        image_url_inputs: true,
        pdf_inputs: true,
        text_outputs: true,
        reasoning_output: true,
        tool_calling: true,
        tool_choice: true,
        parallel_tool_calls: true,
        structured_output: true,
        streaming: true,
        usage_metadata: true,
        image_tool_message: true,
        pdf_tool_message: true,
        attachment: true,
        supported_params: Params.anthropic(),
        extra: %{
          cache_read_price_per_mtok: 0.50,
          cache_write_5m_price_per_mtok: 6.25,
          cache_write_1h_price_per_mtok: 10.00,
          input_price_per_mtok: 5.00,
          output_price_per_mtok: 25.00,
          batch_input_price_per_mtok: 2.50,
          batch_output_price_per_mtok: 12.50,
          fast_mode_price_multiplier: 6,
          inference_geo_us_multiplier: 1.1,
          retirement_not_before: "2027-02-05"
        }
      }),
    {:anthropic, "claude-opus-4-5-20251101"} =>
      Profile.new(%{
        provider: :anthropic,
        id: "claude-opus-4-5-20251101",
        name: "Claude Opus 4.5",
        status: :active,
        release_date: "2025-11-24",
        last_updated: "2025-11-24",
        max_input_tokens: 200_000,
        max_output_tokens: 64_000,
        text_inputs: true,
        image_inputs: true,
        image_url_inputs: true,
        pdf_inputs: true,
        text_outputs: true,
        reasoning_output: true,
        tool_calling: true,
        tool_choice: true,
        parallel_tool_calls: true,
        structured_output: false,
        streaming: true,
        usage_metadata: true,
        image_tool_message: true,
        pdf_tool_message: true,
        attachment: true,
        supported_params: Params.anthropic(),
        extra: %{
          cache_read_price_per_mtok: 0.50,
          cache_write_5m_price_per_mtok: 6.25,
          cache_write_1h_price_per_mtok: 10.00,
          input_price_per_mtok: 5.00,
          output_price_per_mtok: 25.00,
          batch_input_price_per_mtok: 2.50,
          batch_output_price_per_mtok: 12.50,
          retirement_not_before: "2026-11-24"
        }
      }),
    {:anthropic, "claude-opus-4-1-20250805"} =>
      Profile.new(%{
        provider: :anthropic,
        id: "claude-opus-4-1-20250805",
        name: "Claude Opus 4.1",
        status: :active,
        release_date: "2025-08-05",
        last_updated: "2025-08-05",
        max_input_tokens: 200_000,
        max_output_tokens: 64_000,
        text_inputs: true,
        image_inputs: true,
        image_url_inputs: true,
        pdf_inputs: true,
        text_outputs: true,
        reasoning_output: true,
        tool_calling: true,
        tool_choice: true,
        parallel_tool_calls: true,
        structured_output: false,
        streaming: true,
        usage_metadata: true,
        image_tool_message: true,
        pdf_tool_message: true,
        attachment: true,
        supported_params: Params.anthropic(),
        extra: %{
          cache_read_price_per_mtok: 1.50,
          cache_write_5m_price_per_mtok: 18.75,
          cache_write_1h_price_per_mtok: 30.00,
          input_price_per_mtok: 15.00,
          output_price_per_mtok: 75.00,
          retirement_not_before: "2026-08-05"
        }
      }),
    {:anthropic, "claude-sonnet-4-6"} =>
      Profile.new(%{
        provider: :anthropic,
        id: "claude-sonnet-4-6",
        name: "Claude Sonnet 4.6",
        status: :active,
        release_date: "2026-02-17",
        last_updated: "2026-02-17",
        max_input_tokens: 1_000_000,
        max_output_tokens: 64_000,
        text_inputs: true,
        image_inputs: true,
        image_url_inputs: true,
        pdf_inputs: true,
        text_outputs: true,
        reasoning_output: true,
        tool_calling: true,
        tool_choice: true,
        parallel_tool_calls: true,
        structured_output: true,
        streaming: true,
        usage_metadata: true,
        image_tool_message: true,
        pdf_tool_message: true,
        attachment: true,
        supported_params: Params.anthropic(),
        extra: %{
          cache_read_price_per_mtok: 0.30,
          cache_write_5m_price_per_mtok: 3.75,
          cache_write_1h_price_per_mtok: 6.00,
          input_price_per_mtok: 3.00,
          output_price_per_mtok: 15.00,
          batch_input_price_per_mtok: 1.50,
          batch_output_price_per_mtok: 7.50,
          inference_geo_us_multiplier: 1.1,
          retirement_not_before: "2027-02-17"
        }
      }),
    {:anthropic, "claude-haiku-4-5-20251001"} =>
      Profile.new(%{
        provider: :anthropic,
        id: "claude-haiku-4-5-20251001",
        name: "Claude Haiku 4.5",
        release_date: "2025-10-15",
        last_updated: "2025-10-15",
        max_input_tokens: 200_000,
        max_output_tokens: 64_000,
        text_inputs: true,
        image_inputs: true,
        image_url_inputs: true,
        pdf_inputs: true,
        text_outputs: true,
        reasoning_output: true,
        tool_calling: true,
        tool_choice: true,
        parallel_tool_calls: true,
        structured_output: false,
        streaming: true,
        usage_metadata: true,
        image_tool_message: true,
        pdf_tool_message: true,
        attachment: true,
        supported_params: Params.anthropic()
      }),
    {:anthropic, "claude-haiku-4-5"} =>
      Profile.new(%{
        provider: :anthropic,
        id: "claude-haiku-4-5",
        name: "Claude Haiku 4.5 (latest)",
        release_date: "2025-10-15",
        last_updated: "2025-10-15",
        max_input_tokens: 200_000,
        max_output_tokens: 64_000,
        text_inputs: true,
        image_inputs: true,
        image_url_inputs: true,
        pdf_inputs: true,
        text_outputs: true,
        reasoning_output: true,
        tool_calling: true,
        tool_choice: true,
        parallel_tool_calls: true,
        structured_output: true,
        streaming: true,
        usage_metadata: true,
        image_tool_message: true,
        pdf_tool_message: true,
        attachment: true,
        supported_params: Params.anthropic()
      }),
    {:anthropic, "claude-sonnet-4-5-20250929"} =>
      Profile.new(%{
        provider: :anthropic,
        id: "claude-sonnet-4-5-20250929",
        name: "Claude Sonnet 4.5",
        release_date: "2025-09-29",
        last_updated: "2025-09-29",
        max_input_tokens: 200_000,
        max_output_tokens: 64_000,
        text_inputs: true,
        image_inputs: true,
        image_url_inputs: true,
        pdf_inputs: true,
        text_outputs: true,
        reasoning_output: true,
        tool_calling: true,
        tool_choice: true,
        parallel_tool_calls: true,
        structured_output: false,
        streaming: true,
        usage_metadata: true,
        image_tool_message: true,
        pdf_tool_message: true,
        attachment: true,
        supported_params: Params.anthropic()
      }),
    {:anthropic, "claude-sonnet-4-5"} =>
      Profile.new(%{
        provider: :anthropic,
        id: "claude-sonnet-4-5",
        name: "Claude Sonnet 4.5 (latest)",
        release_date: "2025-09-29",
        last_updated: "2025-09-29",
        max_input_tokens: 200_000,
        max_output_tokens: 64_000,
        text_inputs: true,
        image_inputs: true,
        image_url_inputs: true,
        pdf_inputs: true,
        text_outputs: true,
        reasoning_output: true,
        tool_calling: true,
        tool_choice: true,
        parallel_tool_calls: true,
        structured_output: true,
        streaming: true,
        usage_metadata: true,
        image_tool_message: true,
        pdf_tool_message: true,
        attachment: true,
        supported_params: Params.anthropic()
      }),
    {:anthropic, "claude-opus-4-5"} =>
      Profile.new(%{
        provider: :anthropic,
        id: "claude-opus-4-5",
        name: "Claude Opus 4.5 (latest)",
        release_date: "2025-11-24",
        last_updated: "2025-11-24",
        max_input_tokens: 200_000,
        max_output_tokens: 64_000,
        text_inputs: true,
        image_inputs: true,
        image_url_inputs: true,
        pdf_inputs: true,
        text_outputs: true,
        reasoning_output: true,
        tool_calling: true,
        tool_choice: true,
        parallel_tool_calls: true,
        structured_output: true,
        streaming: true,
        usage_metadata: true,
        image_tool_message: true,
        pdf_tool_message: true,
        attachment: true,
        supported_params: Params.anthropic()
      })
  }
  def profiles_map, do: @profiles
  def profiles, do: Map.values(@profiles)

  def resolve(model) do
    cond do
      Map.has_key?(@anthropic_deprecated_models, model) ->
        deprecated_model_error(model)

      Map.has_key?(@anthropic_retired_models, model) ->
        retired_model_error(model)

      true ->
        fetch_or_fallback(@profiles, :anthropic, model)
    end
  end

  defp deprecated_model_error(model) do
    metadata = Map.fetch!(@anthropic_deprecated_models, model)
    replacement = metadata.replacement

    {:error,
     Error.new(:deprecated_model, "Anthropic model is deprecated", %{
       provider: :anthropic,
       model: model,
       replacement: replacement,
       expected: "anthropic:#{replacement}",
       deprecated_at: metadata.deprecated_at,
       retirement_date: metadata.retirement_date
     })}
  end

  defp retired_model_error(model) do
    metadata = Map.fetch!(@anthropic_retired_models, model)
    replacement = metadata.replacement

    {:error,
     Error.new(:deprecated_model, "Anthropic model is retired", %{
       provider: :anthropic,
       model: model,
       replacement: replacement,
       expected: "anthropic:#{replacement}",
       retirement_date: metadata.retirement_date
     })}
  end

  defp fetch_or_fallback(profiles, provider, model) do
    case Map.fetch(profiles, {provider, model}) do
      {:ok, profile} -> {:ok, profile}
      :error -> {:fallback, provider, model}
    end
  end
end
