defmodule BeamWeaver.Graph.Managed.IsLastStep do
  @moduledoc """
  Managed value that reports whether the current superstep is the last allowed step.
  """

  @behaviour BeamWeaver.Graph.ManagedValue

  defstruct [:key]

  def new(opts \\ []), do: %__MODULE__{key: Keyword.get(opts, :key)}

  @impl true
  def get(%__MODULE__{}, runtime) do
    is_integer(runtime.recursion_limit) and runtime.recursion_limit <= 1
  end
end
