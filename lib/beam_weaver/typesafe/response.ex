defmodule BeamWeaver.TypeSafe.ChoiceAnswer do
  @moduledoc "A selected option with its probability distribution and reported confidence."
  defstruct [:choice, :confidence, probabilities: %{}, type: :choice]
end

defmodule BeamWeaver.TypeSafe.ScoreAnswer do
  @moduledoc "An expected position on an ordered rubric; legend values retain their JSON structure."
  defstruct [:score, :confidence, legend: %{}, probabilities: %{}, type: :score]
end

defmodule BeamWeaver.TypeSafe.NoulAnswer do
  @moduledoc "The probability of yes, from 0 to 1. There is no separate confidence field."
  defstruct [:noul, type: :noul]
end

defmodule BeamWeaver.TypeSafe.Response do
  @moduledoc """
  A complete Jev evaluation. Answers are keyed by string question IDs.

  `model` is the resolved provider version; `requested_model` retains the alias
  or version requested. `usage` uses atom token-count keys. Cache hits report
  zero new usage and retain the original usage in `metadata`.
  """
  defstruct [:model, :requested_model, :request_id, :latency_ms, answers: %{}, usage: %{}, metadata: %{}]
  @type t :: %__MODULE__{}

  @doc false
  def from_serialized(fields) do
    response = struct(__MODULE__, fields)
    metadata = BeamWeaver.MapAccess.normalize_keys(response.metadata, [:cost, :cache_hit, :original_usage])

    metadata =
      if Map.has_key?(metadata, :original_usage),
        do: Map.update!(metadata, :original_usage, &usage_keys/1),
        else: metadata

    metadata = if Map.has_key?(metadata, :cost), do: Map.update!(metadata, :cost, &cost_keys/1), else: metadata
    %{response | usage: usage_keys(response.usage), metadata: metadata}
  end

  defp usage_keys(usage), do: BeamWeaver.MapAccess.normalize_keys(usage, [:input_tokens, :output_tokens, :total_tokens])

  defp cost_keys(cost) do
    cost =
      BeamWeaver.MapAccess.normalize_keys(cost, [
        :input_cost,
        :output_cost,
        :total_cost,
        :input_cost_details,
        :output_cost_details
      ])

    if is_map(cost) do
      Enum.reduce([:input_cost_details, :output_cost_details], cost, fn key, acc ->
        if Map.has_key?(acc, key),
          do: Map.update!(acc, key, &BeamWeaver.MapAccess.normalize_keys(&1, [:uncached, :cache_read, :text])),
          else: acc
      end)
    else
      cost
    end
  end

  @doc false
  def cached(%__MODULE__{} = response) do
    response = from_serialized(Map.from_struct(response))

    %{
      response
      | usage: %{input_tokens: 0, output_tokens: 0, total_tokens: 0},
        latency_ms: 0,
        metadata:
          response.metadata
          |> Map.put(:cache_hit, true)
          |> Map.put(:original_usage, response.usage)
          |> Map.put(:cost, %{input_cost: 0.0, output_cost: 0.0, total_cost: 0.0})
    }
  end
end
