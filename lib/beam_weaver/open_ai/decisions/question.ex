defmodule BeamWeaver.OpenAI.Decisions.Question do
  @moduledoc """
  Questions for OpenAI's Decisions API, answered by
  `BeamWeaver.OpenAI.DecisionModel`.

    * `predicate/1` - how likely a statement about the state holds:
      `instructions:`. Answered with a `BeamWeaver.OpenAI.Decisions.PredicateAnswer`.
    * `choice/1` - which of 2 to 255 options fits: `instructions:` and
      `choices:`, each value (a string or a boolean) with a description of
      when it applies, or `nil`, as a map or, to keep their order, a list of
      pairs. Answered with a `BeamWeaver.OpenAI.Decisions.ChoiceAnswer`.
    * `score/1` - a rating on two or more ordered levels: `instructions:` and
      `levels:`, from lowest to highest, each a label or
      `%{label: label, description: description}`. Answered with a
      `BeamWeaver.OpenAI.Decisions.ScoreAnswer`.

  Put the whole question in `instructions`: the question's key in
  `questions` only names its answer. Questions are checked when the model is
  asked them.
  """

  defstruct [:type, :instructions, :choices, :levels]

  @type t :: %__MODULE__{
          type: :predicate | :choice | :score,
          instructions: String.t(),
          choices: map() | [{String.t() | boolean(), String.t() | nil}] | nil,
          levels: [String.t() | map()] | nil
        }

  def predicate(opts), do: new(:predicate, opts)
  def choice(opts), do: new(:choice, opts)
  def score(opts), do: new(:score, opts)

  defp new(type, opts), do: struct!(__MODULE__, opts |> Map.new() |> Map.put(:type, type))
end
