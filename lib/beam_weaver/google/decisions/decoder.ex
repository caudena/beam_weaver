defmodule BeamWeaver.Google.Decisions.Decoder do
  @moduledoc false

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Google.Decisions.{ChoiceAnswer, NoulAnswer, Response, ScoreAnswer}
  alias BeamWeaver.{MapShape, Result}

  defguardp probability?(value) when is_number(value) and value >= 0 and value <= 1

  def decode(%{"answers" => answers, "usage" => usage} = raw, model)
      when is_map(answers) and is_map(usage) do
    with {:ok, entries} <- Result.traverse(answers, &decode_entry/1),
         {:ok, usage} <- decode_usage(usage) do
      {:ok,
       %Response{
         model: raw["model"] || model,
         requested_model: model,
         request_id: get_in(raw, ["_beamweaver_response_header_metadata", :request_id]),
         answers: Map.new(entries),
         usage: usage
       }}
    end
  end

  def decode(_raw, _model), do: invalid()

  defp decode_entry({key, answer}) when is_binary(key) do
    with {:ok, decoded} <- decode_answer(answer), do: {:ok, {key, decoded}}
  end

  defp decode_entry(_entry), do: invalid()

  defp decode_answer(%{"type" => "noul", "noul" => value, "confidence" => confidence})
       when probability?(value) and probability?(confidence),
       do: {:ok, %NoulAnswer{noul: value, confidence: confidence}}

  defp decode_answer(%{"type" => "choice", "choice" => choice, "confidence" => confidence, "probabilities" => values})
       when is_binary(choice) and probability?(confidence) and is_map(values) do
    if Map.has_key?(values, choice) and Enum.all?(values, fn {key, value} -> is_binary(key) and probability?(value) end),
      do: {:ok, %ChoiceAnswer{choice: choice, confidence: confidence, probabilities: values}},
      else: invalid()
  end

  defp decode_answer(%{
         "type" => "score",
         "score" => score,
         "confidence" => confidence,
         "probabilities" => values,
         "legend" => legend
       })
       when is_number(score) and probability?(confidence) and is_map(values) and is_map(legend) do
    with {:ok, probabilities} <- indexed(values, &probability?/1),
         {:ok, legend} <- indexed(legend, &is_binary/1),
         true <- same_levels?(probabilities, legend) do
      {:ok, %ScoreAnswer{score: score, confidence: confidence, probabilities: probabilities, legend: legend}}
    else
      _ -> invalid()
    end
  end

  defp decode_answer(_), do: invalid()

  defp same_levels?(probabilities, legend) do
    map_size(probabilities) == map_size(legend) and
      Enum.all?(probabilities, fn {index, _probability} -> Map.has_key?(legend, index) end)
  end

  defp indexed(values, valid?) do
    with {:ok, entries} <-
           Result.traverse(values, fn
             {key, value} when is_binary(key) ->
               case Integer.parse(key) do
                 {index, ""} when index >= 0 ->
                   if valid?.(value), do: {:ok, {index, value}}, else: invalid()

                 _ ->
                   invalid()
               end

             _entry ->
               invalid()
           end),
         indexed = Map.new(entries),
         true <- map_size(indexed) == map_size(values) do
      {:ok, indexed}
    else
      _ -> invalid()
    end
  end

  defp decode_usage(%{"total_input_tokens" => input} = usage) when is_integer(input) and input >= 0 do
    with output when is_integer(output) and output >= 0 <- Map.get(usage, "total_output_tokens", 0),
         total when is_integer(total) and total >= input + output <- Map.get(usage, "total_tokens", input + output) do
      {:ok,
       MapShape.reject_nil_or_empty(%{
         input_tokens: input,
         output_tokens: output,
         total_tokens: total,
         input_tokens_by_modality: usage["input_tokens_by_modality"]
       })}
    else
      _ -> invalid()
    end
  end

  defp decode_usage(_), do: invalid()

  defp invalid, do: {:error, Error.new(:invalid_provider_response, "invalid Gemini Decisions response")}
end
