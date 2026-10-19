defmodule BeamWeaver.OpenAI.Decisions.PredicateAnswer do
  @moduledoc "The probability, from 0 to 1, that a predicate holds."
  defstruct [:probability, type: :predicate]
end

defmodule BeamWeaver.OpenAI.Decisions.ChoiceAnswer do
  @moduledoc """
  The chosen value, the probability of each value, and `confidence`: how
  concentrated the probabilities are, not the chosen value's probability.
  """
  defstruct [:choice, :confidence, probabilities: %{}, type: :choice]
end

defmodule BeamWeaver.OpenAI.Decisions.ScoreAnswer do
  @moduledoc """
  The expected level, from 0 to the last level's index, so it may fall
  between levels. `probabilities` and `legend` map each level's index to its
  probability and its label.
  """
  defstruct [:score, :confidence, legend: %{}, probabilities: %{}, type: :score]
end

defmodule BeamWeaver.OpenAI.Decisions.RefusalAnswer do
  @moduledoc "The model declined to answer this question; the others in the request may still have answers."
  defstruct type: :refusal
end

defmodule BeamWeaver.OpenAI.Decisions.Response do
  @moduledoc """
  A Decisions API response. `answers` maps each question's name, as a
  string, to its answer; a question the model didn't answer, such as one
  with an answer of a type added to the API since, has none. `model` is the
  model that answered and `requested_model` the one asked for. `usage` has
  atom token-count keys. A cache hit reports zero new usage and cost, and
  keeps the original usage in `metadata`.
  """

  defstruct [:model, :requested_model, :request_id, :latency_ms, answers: %{}, usage: %{}, metadata: %{}]

  @type t :: %__MODULE__{}

  @doc false
  def cached(%__MODULE__{} = response) do
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
