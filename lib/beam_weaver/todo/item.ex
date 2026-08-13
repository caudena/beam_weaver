defmodule BeamWeaver.Todo.Item do
  @moduledoc """
  One immutable Todo item carried between `BeamWeaver.Todo` revisions.

  Applications own the meaning of evidence references. BeamWeaver only checks
  that a state transition carries the required evidence kind.
  """

  @statuses [:pending, :in_progress, :blocked, :completed, :cancelled]

  @enforce_keys [:id, :content]
  defstruct [:id, :content, :owner, :assignment_id, :blocker, dependencies: [], status: :pending, evidence: []]

  @type status :: :pending | :in_progress | :blocked | :completed | :cancelled
  @type evidence :: %{kind: atom(), ref: String.t()}

  @type t :: %__MODULE__{
          id: String.t(),
          content: String.t(),
          dependencies: [String.t()],
          status: status(),
          owner: String.t() | nil,
          assignment_id: String.t() | nil,
          blocker: String.t() | nil,
          evidence: [evidence()]
        }

  @doc false
  def statuses, do: @statuses
end
