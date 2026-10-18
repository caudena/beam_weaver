defmodule BeamWeaver.Core.Error do
  @moduledoc ~S"""
  Tagged failure data returned by provider and runtime operations.

  `type` is an atom for application branching, `message` is explanatory text
  and `details` contains operation-specific data such as provider status,
  retryability, field names or pending-work metadata. This is a result value,
  not an exception to raise directly.

  Handle error types rather than matching provider wording. Only retry within
  an explicit policy and do not assume an external action did not happen merely
  because its response timed out. See [Models](models.md#errors) and
  [Durable Execution](durable_execution.md).
  """

  @enforce_keys [:type, :message]
  defstruct [:type, :message, details: %{}]

  @type t :: %__MODULE__{
          type: atom(),
          message: String.t(),
          details: map()
        }

  @doc """
  Builds a core error.
  """
  @spec new(atom(), String.t(), map()) :: t()
  def new(type, message, details \\ %{}) when is_atom(type) and is_binary(message) do
    %__MODULE__{type: type, message: message, details: details}
  end
end
