defmodule BeamWeaver.Graph.Resume do
  @moduledoc """
  Explicit resume values for graph interrupts.

  Plain Elixir values work for normal resumes. Use `null/0` when the intended
  resume value is `nil`, because bare `nil` is indistinguishable from "no
  resume value was supplied" at API boundaries.
  """

  defstruct [:value, null?: false]

  @type t :: %__MODULE__{value: term(), null?: boolean()}

  @spec null() :: t()
  def null, do: %__MODULE__{null?: true}

  @spec value(term()) :: t()
  def value(value), do: %__MODULE__{value: value}
end
