defmodule BeamWeaver.OpenAI.ChatCompletions.Options.Validation do
  @moduledoc false

  alias BeamWeaver.Models.ParamPolicy
  alias BeamWeaver.OpenAI.Error
  alias BeamWeaver.OpenAI.ModelPolicy

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
        :moderation,
        :model_kwargs,
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

    with :ok <- validate_function_tools(model, opts),
         :ok <-
           ParamPolicy.validate(
             Map.get(model, :profile),
             params,
             Keyword.get(opts, :param_policy, Map.get(model, :param_policy)),
             api: :chat_completions,
             metadata: Keyword.get(opts, :metadata, %{})
           ),
         :ok <- validate_astra_reasoning_effort(model, opts) do
      :ok
    end
  end

  defp validate_function_tools(model, opts) do
    model_name = Keyword.get(opts, :model, Map.get(model, :model))
    reasoning_effort = Keyword.get(opts, :reasoning_effort, Map.get(model, :reasoning_effort))

    cond do
      ModelPolicy.astra?(model_name) and function_tools?(model, opts) ->
        {:error,
         Error.new(
           :invalid_model_option,
           "GPT-6 Astra function tools require the Responses API",
           %{model: model_name, alternative_api: :responses}
         )}

      gpt56?(model_name) and function_tools?(model, opts) and
          reasoning_effort not in [:none, "none"] ->
        {:error,
         Error.new(
           :invalid_model_option,
           "GPT-5.6 Chat Completions function tools require reasoning_effort: :none",
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

  defp validate_astra_reasoning_effort(model, opts) do
    model_name = Keyword.get(opts, :model, Map.get(model, :model))
    reasoning_effort = Keyword.get(opts, :reasoning_effort, Map.get(model, :reasoning_effort))

    if ModelPolicy.reasoning_effort_supported?(model_name, reasoning_effort) do
      :ok
    else
      {:error,
       Error.new(
         :invalid_model_option,
         "GPT-6 Astra reasoning effort must be low, medium, high, xhigh, or max",
         %{
           model: model_name,
           reasoning_effort: reasoning_effort,
           supported: [:low, :medium, :high, :xhigh, :max]
         }
       )}
    end
  end

  defp function_tools?(model, opts) do
    model_kwargs = Keyword.get(opts, :model_kwargs, Map.get(model, :model_kwargs, %{})) || %{}

    non_empty_list?(Keyword.get(opts, :tools) || map_option(model_kwargs, :tools)) or
      non_empty_list?(
        Keyword.get(opts, :functions, Map.get(model, :functions)) ||
          map_option(model_kwargs, :functions)
      )
  end

  defp map_option(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp map_option(_map, _key), do: nil

  defp non_empty_list?([_first | _rest]), do: true
  defp non_empty_list?(_value), do: false

  defp gpt56?(model) when is_binary(model), do: String.starts_with?(String.downcase(model), "gpt-5.6")
  defp gpt56?(_model), do: false
end
