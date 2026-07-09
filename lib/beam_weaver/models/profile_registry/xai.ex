defmodule BeamWeaver.Models.ProfileRegistry.XAI do
  @moduledoc false

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Models.Profile
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
    "grok-latest" => "grok-4.5",
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
    "grok-imagine-image" => "grok-imagine image APIs are not exposed through chat models",
    "grok-imagine-image-quality" => "grok-imagine image APIs are not exposed through chat models",
    "grok-imagine-video" => "grok-imagine video APIs are not exposed through chat models"
  }

  @profiles %{
    {:xai, "grok-4.5"} =>
      Profile.new(%{
        provider: :xai,
        id: "grok-4.5",
        name: "Grok 4.5",
        release_date: "2026-07-08",
        last_updated: "2026-07-08",
        responses_api: true,
        chat_completions_api: true,
        max_input_tokens: 500_000,
        max_output_tokens: 30_000,
        text_inputs: true,
        image_inputs: true,
        image_url_inputs: true,
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
        tokenizer: :o200k_base,
        extra: %{
          input_price_per_mtok: 2.00,
          cached_input_price_per_mtok: 0.50,
          output_price_per_mtok: 6.00,
          default_reasoning_effort: :high,
          reasoning_efforts: [:low, :medium, :high],
          higher_context_pricing_threshold_tokens: 200_000,
          regions: ["us-east-1", "us-west-2"]
        }
      }),
    {:xai, "grok-4.3"} =>
      Profile.new(%{
        provider: :xai,
        id: "grok-4.3",
        name: "Grok 4.3",
        release_date: "2026-05-01",
        last_updated: "2026-05-01",
        responses_api: true,
        chat_completions_api: true,
        max_input_tokens: 1_000_000,
        max_output_tokens: 30_000,
        text_inputs: true,
        image_inputs: true,
        image_url_inputs: true,
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
        tokenizer: :o200k_base,
        extra: %{
          input_price_per_mtok: 1.25,
          cached_input_price_per_mtok: 0.20,
          output_price_per_mtok: 2.50,
          batch_discount_rate: 0.20
        }
      }),
    {:xai, "grok-4.20-0309-reasoning"} =>
      Profile.new(%{
        provider: :xai,
        id: "grok-4.20-0309-reasoning",
        name: "Grok 4.20 (Reasoning)",
        release_date: "2026-03-09",
        last_updated: "2026-03-09",
        responses_api: true,
        chat_completions_api: true,
        max_input_tokens: 1_000_000,
        max_output_tokens: 30_000,
        text_inputs: true,
        image_inputs: true,
        image_url_inputs: true,
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
        tokenizer: :o200k_base,
        extra: %{
          input_price_per_mtok: 1.25,
          cached_input_price_per_mtok: 0.20,
          output_price_per_mtok: 2.50,
          batch_discount_rate: 0.20
        }
      }),
    {:xai, "grok-4.20-0309-non-reasoning"} =>
      Profile.new(%{
        provider: :xai,
        id: "grok-4.20-0309-non-reasoning",
        name: "Grok 4.20 (Non-Reasoning)",
        release_date: "2026-03-09",
        last_updated: "2026-03-09",
        responses_api: true,
        chat_completions_api: true,
        max_input_tokens: 1_000_000,
        max_output_tokens: 30_000,
        text_inputs: true,
        image_inputs: true,
        image_url_inputs: true,
        text_outputs: true,
        reasoning_output: false,
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
        tokenizer: :o200k_base,
        extra: %{
          input_price_per_mtok: 1.25,
          cached_input_price_per_mtok: 0.20,
          output_price_per_mtok: 2.50,
          batch_discount_rate: 0.20
        }
      }),
    {:xai, "grok-build-0.1"} =>
      Profile.new(%{
        provider: :xai,
        id: "grok-build-0.1",
        name: "Grok Build 0.1",
        release_date: "2026-03-09",
        last_updated: "2026-03-09",
        responses_api: true,
        chat_completions_api: true,
        max_input_tokens: 256_000,
        max_output_tokens: 30_000,
        text_inputs: true,
        image_inputs: true,
        image_url_inputs: true,
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
        tokenizer: :o200k_base,
        extra: %{
          input_price_per_mtok: 1.00,
          cached_input_price_per_mtok: 0.20,
          output_price_per_mtok: 2.00
        }
      }),
    {:xai, "grok-4.20-multi-agent-0309"} =>
      Profile.new(%{
        provider: :xai,
        id: "grok-4.20-multi-agent-0309",
        name: "Grok 4.20 Multi-Agent Beta",
        release_date: "2026-03-09",
        last_updated: "2026-03-09",
        responses_api: true,
        chat_completions_api: true,
        max_input_tokens: 1_000_000,
        max_output_tokens: 30_000,
        text_inputs: true,
        image_inputs: true,
        image_url_inputs: true,
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
        tokenizer: :o200k_base,
        extra: %{
          input_price_per_mtok: 1.25,
          cached_input_price_per_mtok: 0.20,
          output_price_per_mtok: 2.50,
          batch_discount_rate: 0.20
        }
      }),
    {:xai, "v1"} =>
      Profile.new(%{
        provider: :xai,
        id: "v1",
        name: "xAI Embedding v1",
        supported_params: Params.xai_embedding(),
        text_inputs: true,
        text_outputs: false,
        tokenizer: :o200k_base,
        extra: %{
          api_family: :embeddings,
          embedding_model: true
        }
      })
  }
  def profiles_map, do: @profiles
  def profiles, do: Map.values(@profiles)

  def resolve(model) do
    cond do
      Map.has_key?(@xai_deprecated_models, model) ->
        deprecated_model_error(model)

      Map.has_key?(@xai_non_chat_models, model) ->
        non_chat_model_error(model)

      Map.has_key?(@xai_chat_aliases, model) ->
        alias_profile(model, Map.fetch!(@xai_chat_aliases, model))

      true ->
        fetch_or_fallback(@profiles, :xai, model)
    end
  end

  defp deprecated_model_error(model) do
    metadata = Map.fetch!(@xai_deprecated_models, model)
    replacement = metadata.replacement

    details =
      %{
        provider: :xai,
        model: model,
        replacement: replacement,
        expected: "xai:#{replacement}",
        retired_at: "2026-05-15T12:00:00-07:00"
      }
      |> maybe_put_detail(:reasoning_effort, Map.get(metadata, :reasoning_effort))

    {:error, Error.new(:deprecated_model, "xAI model is retired or redirected", details)}
  end

  defp non_chat_model_error(model) do
    {:error,
     Error.new(:unsupported_model, "xAI model is not a chat model", %{
       provider: :xai,
       model: model,
       reason: Map.fetch!(@xai_non_chat_models, model)
     })}
  end

  defp alias_profile(alias_id, canonical_id) do
    case Map.fetch(@profiles, {:xai, canonical_id}) do
      {:ok, profile} ->
        extra =
          profile.extra
          |> Map.put(:canonical_model, canonical_id)
          |> Map.put(:alias_model, alias_id)

        {:ok, %{profile | id: alias_id, name: "#{profile.name} (alias)", extra: extra}}

      :error ->
        {:fallback, :xai, alias_id}
    end
  end

  defp maybe_put_detail(details, _key, nil), do: details
  defp maybe_put_detail(details, key, value), do: Map.put(details, key, value)

  defp fetch_or_fallback(profiles, provider, model) do
    case Map.fetch(profiles, {provider, model}) do
      {:ok, profile} -> {:ok, profile}
      :error -> {:fallback, provider, model}
    end
  end
end
