defmodule BeamWeaver.OpenAI.Decisions.Decoder do
  @moduledoc false

  alias BeamWeaver.Core.Error
  alias BeamWeaver.MapShape
  alias BeamWeaver.OpenAI.Decisions.{ChoiceAnswer, PredicateAnswer, RefusalAnswer, Response, ScoreAnswer}
  alias BeamWeaver.Result

  @answer_types ~w(predicate choice score refusal)

  defguardp probability?(value) when is_number(value) and value >= 0 and value <= 1

  def decode(%{"model" => model, "answers" => answers} = body) when is_binary(model) and is_list(answers) do
    with {:ok, answers} <- Result.flat_traverse(answers, &answer/1) do
      {:ok,
       %Response{
         model: model,
         request_id: get_in(body, ["_beamweaver_response_header_metadata", :request_id]),
         answers: Map.new(answers),
         usage: usage(body["usage"])
       }}
    end
  end

  def decode(_body), do: invalid()

  defp answer(%{"type" => "predicate", "name" => name, "probability" => probability})
       when is_binary(name) and probability?(probability),
       do: {:ok, {name, %PredicateAnswer{probability: probability}}}

  defp answer(%{"type" => "choice", "name" => name, "choice" => choice, "confidence" => confidence} = answer)
       when is_binary(name) and probability?(confidence) do
    with {:ok, probabilities} <- distribution(answer["probabilities"], &(is_binary(&1) or is_boolean(&1))) do
      {:ok, {name, %ChoiceAnswer{choice: choice, confidence: confidence, probabilities: probabilities}}}
    end
  end

  defp answer(%{"type" => "score", "name" => name, "score" => score, "confidence" => confidence} = answer)
       when is_binary(name) and is_number(score) and probability?(confidence) do
    with {:ok, probabilities} <- distribution(answer["probabilities"], &is_integer/1) do
      legend = Map.new(answer["probabilities"], &{&1["value"], &1["label"]})
      {:ok, {name, %ScoreAnswer{score: score, confidence: confidence, legend: legend, probabilities: probabilities}}}
    end
  end

  defp answer(%{"type" => "refusal", "name" => name}) when is_binary(name), do: {:ok, {name, %RefusalAnswer{}}}

  # An answer of a type added to the API since is left out, so its question
  # reads as unanswered.
  defp answer(%{"type" => type, "name" => name}) when is_binary(type) and is_binary(name) and type not in @answer_types,
    do: {:ok, []}

  defp answer(_answer), do: invalid()

  defp distribution(entries, value?) when is_list(entries) do
    entries
    |> Result.traverse(fn
      %{"value" => value, "probability" => probability} when probability?(probability) ->
        if value?.(value), do: {:ok, {value, probability}}, else: invalid()

      _entry ->
        invalid()
    end)
    |> case do
      {:ok, probabilities} -> {:ok, Map.new(probabilities)}
      {:error, _error} = error -> error
    end
  end

  defp distribution(_entries, _value?), do: invalid()

  defp usage(%{"input_tokens" => input, "output_tokens" => output} = usage)
       when is_integer(input) and is_integer(output) do
    MapShape.reject_nil_or_empty(%{
      input_tokens: input,
      output_tokens: output,
      total_tokens: usage["total_tokens"] || input + output,
      input_token_details:
        MapShape.reject_nil_or_empty(%{
          cache_read: detail(usage, "input_tokens_details", "cached_tokens"),
          cache_write: detail(usage, "input_tokens_details", "cache_write_tokens")
        }),
      output_token_details:
        MapShape.reject_nil_or_empty(%{reasoning: detail(usage, "output_tokens_details", "reasoning_tokens")})
    })
  end

  defp usage(_usage), do: %{input_tokens: 0, output_tokens: 0, total_tokens: 0}

  defp detail(usage, group, key) do
    case usage[group] do
      %{^key => count} when is_integer(count) -> count
      _missing -> nil
    end
  end

  defp invalid, do: {:error, Error.new(:invalid_provider_response, "invalid OpenAI Decisions response")}
end
