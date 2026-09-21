defmodule BeamWeaver.TypeSafe.Decoder do
  @moduledoc false

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Provider.Validation
  alias BeamWeaver.Result
  alias BeamWeaver.TypeSafe.{ChoiceAnswer, NoulAnswer, Response, ScoreAnswer}

  # Provider distributions are rounded; do not require exact floating-point equality.
  @rounding_tolerance 0.02

  def decode(body, questions, requested_model, request_id, opts \\ []) do
    with {:ok, _bounds} <- Validation.measure(body, opts),
         %{"model" => model, "answers" => answers, "usage" => usage} <- body,
         true <- is_binary(model) and model != "" and is_map(answers),
         true <- same_keys?(answers, questions),
         {:ok, decoded} <-
           Result.traverse(questions, fn {id, question} ->
             with {:ok, answer} <- answer(Map.get(answers, id), question), do: {:ok, {id, answer}}
           end),
         {:ok, usage} <- usage(usage) do
      {:ok,
       %Response{
         model: model,
         requested_model: requested_model,
         request_id: request_id,
         answers: Map.new(decoded),
         usage: usage
       }}
    else
      {:error, error} -> {:error, error}
      _ -> invalid()
    end
  end

  defp answer(%{"type" => "noul", "noul" => value}, %{"type" => "noul"})
       when is_number(value) and value >= 0 and value <= 1,
       do: {:ok, %NoulAnswer{noul: value}}

  defp answer(
         %{"type" => "choice", "choice" => choice, "confidence" => confidence, "probabilities" => probabilities},
         %{"type" => "choice", "criteria" => criteria}
       ) do
    if probability?(confidence) and distribution?(probabilities, Map.keys(criteria)) and
         Map.has_key?(criteria, choice) and probabilities[choice] >= Enum.max(Map.values(probabilities)) do
      {:ok, %ChoiceAnswer{choice: choice, confidence: confidence, probabilities: probabilities}}
    else
      invalid()
    end
  end

  defp answer(
         %{
           "type" => "score",
           "score" => score,
           "confidence" => confidence,
           "probabilities" => probabilities,
           "legend" => legend
         },
         %{"type" => "score", "criteria" => criteria}
       ) do
    keys = Enum.map(0..(length(criteria) - 1), &Integer.to_string/1)
    expected_legend = criteria |> Enum.with_index() |> Map.new(fn {v, i} -> {to_string(i), v} end)

    if probability?(confidence) and is_number(score) and score >= 0 and score <= length(criteria) - 1 and
         distribution?(probabilities, keys) and legend == expected_legend do
      {:ok, %ScoreAnswer{score: score, confidence: confidence, probabilities: probabilities, legend: legend}}
    else
      invalid()
    end
  end

  defp answer(_, _), do: invalid()

  defp usage(%{"input_tokens" => input, "output_tokens" => output})
       when is_integer(input) and input >= 0 and is_integer(output) and output >= 0,
       do: {:ok, %{input_tokens: input, output_tokens: output, total_tokens: input + output}}

  defp usage(_), do: invalid()

  defp probability?(v), do: is_number(v) and v >= 0 and v <= 1

  defp distribution?(map, keys) when is_map(map) do
    MapSet.new(Map.keys(map)) == MapSet.new(keys) and Enum.all?(Map.values(map), &probability?/1) and
      abs(Enum.sum(Map.values(map)) - 1) <= @rounding_tolerance
  end

  defp distribution?(_, _), do: false
  defp same_keys?(a, b), do: MapSet.new(Map.keys(a)) == MapSet.new(Map.keys(b))
  defp invalid, do: {:error, Error.new(:invalid_provider_response, "invalid TypeSafe decision response")}
end
