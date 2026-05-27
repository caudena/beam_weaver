defmodule BeamWeaver.Graph.Managed.RemainingSteps do
  @moduledoc """
  Managed value that reports remaining graph recursion steps.
  """

  @behaviour BeamWeaver.Graph.ManagedValue

  defstruct [:key]

  def new(opts \\ []), do: %__MODULE__{key: Keyword.get(opts, :key)}

  @impl true
  def get(%__MODULE__{}, runtime) do
    if is_integer(runtime.recursion_limit), do: max(runtime.recursion_limit, 0), else: nil
  end
end
