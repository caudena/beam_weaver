defmodule BeamWeaver.Google.Decisions.NoulAnswer do
  @moduledoc "The probability of yes and the confidence in the top outcome."
  defstruct [:noul, :confidence, type: :noul]
end

defmodule BeamWeaver.Google.Decisions.ChoiceAnswer do
  @moduledoc "A selected option, its distribution, and the confidence in the selected option."
  defstruct [:choice, :confidence, probabilities: %{}, type: :choice]
end

defmodule BeamWeaver.Google.Decisions.ScoreAnswer do
  @moduledoc "A probability-weighted score with its confidence and distributions keyed by level index."
  defstruct [:score, :confidence, legend: %{}, probabilities: %{}, type: :score]
end

defmodule BeamWeaver.Google.Decisions.Response do
  @moduledoc "Gemini Decision answers keyed by question ID, with request identity, usage and estimated cost."

  defstruct [:model, :requested_model, :request_id, :latency_ms, answers: %{}, usage: %{}, metadata: %{}]
  @type t :: %__MODULE__{}

  @doc false
  def cached(%__MODULE__{} = response), do: BeamWeaver.Core.DecisionModel.cached_response(response)
end
