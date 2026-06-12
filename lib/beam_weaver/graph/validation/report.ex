defmodule BeamWeaver.Graph.Validation.Report do
  @moduledoc """
  Accumulated graph validation diagnostics.

  Public compile paths still return a single tagged `%BeamWeaver.Core.Error{}`.
  The report exists for tooling and tests that need to show all known static
  problems at once.
  """

  defstruct diagnostics: []

  @type diagnostic :: %{
          type: atom(),
          message: String.t(),
          details: map()
        }

  @type t :: %__MODULE__{diagnostics: [diagnostic()]}

  @spec new([diagnostic()]) :: t()
  def new(diagnostics \\ []), do: %__MODULE__{diagnostics: diagnostics}

  @spec ok?(t()) :: boolean()
  def ok?(%__MODULE__{diagnostics: []}), do: true
  def ok?(%__MODULE__{}), do: false
end
