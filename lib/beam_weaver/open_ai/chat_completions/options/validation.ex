defmodule BeamWeaver.OpenAI.ChatCompletions.Options.Validation do
  @moduledoc false

  alias BeamWeaver.Models.ParamPolicy

  def validate(model, opts) do
    params =
      model
      |> Map.from_struct()
      |> Map.take([
        :audio,
        :frequency_penalty,
        :function_call,
        :functions,
        :logit_bias,
        :max_completion_tokens,
        :max_output_tokens,
        :max_tokens,
        :metadata,
        :modalities,
        :model_kwargs,
        :parallel_tool_calls,
        :presence_penalty,
        :prompt_cache_key,
        :prompt_cache_retention,
        :reasoning_effort,
        :safety_identifier,
        :search_parameters,
        :seed,
        :service_tier,
        :store,
        :temperature,
        :top_p,
        :user,
        :verbosity,
        :web_search_options
      ])
      |> Map.merge(Map.new(opts))

    ParamPolicy.validate(
      Map.get(model, :profile),
      params,
      Keyword.get(opts, :param_policy, Map.get(model, :param_policy)),
      api: :chat_completions,
      metadata: Keyword.get(opts, :metadata, %{})
    )
  end
end
