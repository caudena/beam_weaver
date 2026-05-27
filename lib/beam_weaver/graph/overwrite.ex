defmodule BeamWeaver.Graph.Overwrite do
  @moduledoc """
  Wrapper that bypasses a configured reducer for one state update.
  """

  defstruct [:value]

  @type t :: %__MODULE__{value: term()}

  @spec new(term()) :: t()
  def new(value), do: %__MODULE__{value: value}

  @spec get(term()) :: {:ok, term()} | :error
  def get(%__MODULE__{value: value}), do: {:ok, value}
  def get(%{__overwrite__: value} = map) when map_size(map) == 1, do: {:ok, value}
  def get(%{"__overwrite__" => value} = map) when map_size(map) == 1, do: {:ok, value}
  def get(_value), do: :error
end
