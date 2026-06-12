defmodule BeamWeaver.Runtime.Error do
  @moduledoc """
  Recoverable runtime failure.
  """

  @enforce_keys [:type, :message]
  defstruct [:type, :message, details: %{}]

  @type t :: %__MODULE__{
          type: atom(),
          message: String.t(),
          details: map()
        }

  @doc """
  Builds a runtime error.
  """
  @spec new(atom(), String.t(), map()) :: t()
  def new(type, message, details \\ %{}) when is_atom(type) and is_binary(message) do
    %__MODULE__{type: type, message: message, details: details}
  end
end
