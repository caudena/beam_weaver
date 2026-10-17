defmodule BeamWeaver.OpenAI.ChatCompletions.Options.Validation do
  @moduledoc false

  alias BeamWeaver.Provider.Options
  alias BeamWeaver.Models.ParamPolicy
  alias BeamWeaver.Core.Error
  alias BeamWeaver.OpenAI.ModelPolicy

  def validate(model, opts) do
    model_name = Keyword.get(opts, :model, Map.get(model, :model))
    effort = Keyword.get(opts, :reasoning_effort, Map.get(model, :reasoning_effort))

    params =
      model
      |> Map.from_struct()
      |> Map.take([
        :audio,
        :extra_body,
        :frequency_penalty,
        :function_call,
        :functions,
        :logit_bias,
        :max_completion_tokens,
        :max_output_tokens,
        :max_tokens,
        :metadata,
        :modalities,
        :moderation,
        :parallel_tool_calls,
        :presence_penalty,
        :prompt_cache_key,
        :prompt_cache_options,
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

    sampling = Enum.reject([:temperature, :top_p, :top_logprobs, :logprobs], &is_nil(Options.option(model, opts, &1)))

    with :ok <- validate_function_tools(model, opts, model_name, effort),
         policy = Options.option(model, opts, :param_policy),
         :ok <- ParamPolicy.validate(Map.get(model, :profile), params, policy, api: :chat_completions),
         :ok <- ModelPolicy.validate_gpt6_effort(model_name, effort, effort),
         :ok <- ModelPolicy.validate_reasoning_effort(Map.get(model, :profile), effort) do
      ModelPolicy.validate_gpt6_sampling(model_name, effort, sampling)
    end
  end

  defp validate_function_tools(model, opts, model_name, reasoning_effort) do
    cond do
      ModelPolicy.responses_tools_only?(model_name) and function_tools?(model, opts) ->
        {:error,
         Error.new(
           :invalid_model_option,
           "This model's function tools require the Responses API",
           %{model: model_name, alternative_api: :responses}
         )}

      (gpt56?(model_name) or ModelPolicy.gpt6_sol_or_luna?(model_name)) and
        function_tools?(model, opts) and
          reasoning_effort not in [:none, "none"] ->
        {:error,
         Error.new(
           :invalid_model_option,
           "This model's Chat Completions function tools require reasoning_effort: :none",
           %{
             model: model_name,
             reasoning_effort: reasoning_effort,
             expected: :none,
             alternative_api: :responses
           }
         )}

      true ->
        :ok
    end
  end

  defp function_tools?(model, opts) do
    extra_body = Options.extra_body(model, opts)

    non_empty_list?(Keyword.get(opts, :tools) || extra_body["tools"]) or
      non_empty_list?(Keyword.get(opts, :functions, Map.get(model, :functions)) || extra_body["functions"])
  end

  defp non_empty_list?([_first | _rest]), do: true
  defp non_empty_list?(_value), do: false

  defp gpt56?(model) when is_binary(model), do: String.starts_with?(String.downcase(model), "gpt-5.6")
  defp gpt56?(_model), do: false
end
