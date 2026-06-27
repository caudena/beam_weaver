defmodule BeamWeaver.Models.ProfileRegistry.OpenAI do
  @moduledoc false

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Models.Profile
  alias BeamWeaver.Models.ProfileRegistry.Params

  @openai_frontier_specs [
    {"gpt-5.5", "GPT-5.5", 400_000, 128_000, true},
    {"gpt-5.5-pro", "GPT-5.5 Pro", 400_000, 128_000, true},
    {"gpt-5.4", "GPT-5.4", 400_000, 128_000, true},
    {"gpt-5.4-pro", "GPT-5.4 Pro", 400_000, 128_000, true},
    {"gpt-5.4-mini", "GPT-5.4 mini", 400_000, 128_000, true},
    {"gpt-5.4-nano", "GPT-5.4 nano", 400_000, 128_000, true},
    {"gpt-5", "GPT-5", 272_000, 128_000, true},
    {"gpt-5-mini", "GPT-5 mini", 400_000, 128_000, true},
    {"gpt-5-nano", "GPT-5 nano", 400_000, 128_000, true},
    {"gpt-4.1", "GPT-4.1", 1_000_000, 32_768, false}
  ]

  @openai_frontier_ids MapSet.new(Enum.map(@openai_frontier_specs, &elem(&1, 0)))

  @openai_frontier_profiles Map.new(
                              @openai_frontier_specs,
                              fn {id, name, max_input_tokens, max_output_tokens, reasoning_output} ->
                                {{:openai, id},
                                 Profile.new(%{
                                   provider: :openai,
                                   id: id,
                                   name: name,
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
                                   max_input_tokens: max_input_tokens,
                                   max_output_tokens: max_output_tokens,
                                   image_inputs: true,
                                   image_url_inputs: true,
                                   audio_inputs: true,
                                   reasoning_output: reasoning_output,
                                   tokenizer: :o200k_base,
                                   extra: %{frontier: true}
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

  @profiles Map.merge(@openai_frontier_profiles, %{
              {:openai, "text-embedding-3-small"} =>
                Profile.new(%{
                  provider: :openai,
                  id: "text-embedding-3-small",
                  name: "Text embedding 3 small",
                  supported_params: Params.embedding(),
                  max_input_tokens: 8_191,
                  tokenizer: :cl100k_base,
                  extra: %{embedding_dimensions: 1536}
                }),
              {:openai, "text-embedding-3-large"} =>
                Profile.new(%{
                  provider: :openai,
                  id: "text-embedding-3-large",
                  name: "Text embedding 3 large",
                  supported_params: Params.embedding(),
                  max_input_tokens: 8_191,
                  tokenizer: :cl100k_base,
                  extra: %{embedding_dimensions: 3072}
                })
            })
  def profiles_map, do: @profiles
  def profiles, do: Map.values(@profiles)
  def frontier_ids, do: @openai_frontier_ids

  def resolve(model) do
    cond do
      Map.has_key?(@openai_deprecated_models, model) ->
        deprecated_model_error(model)

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
