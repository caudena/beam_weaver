defmodule BeamWeaver.Runnable.Each do
  @moduledoc false

  @behaviour BeamWeaver.Runnable

  alias BeamWeaver.Runnable
  alias BeamWeaver.Runnable.Map, as: MapRunnable

  defstruct [:runnable]

  @impl true
  def invoke(%__MODULE__{runnable: runnable}, input, opts) do
    MapRunnable.invoke(%MapRunnable{runnable: runnable}, List.wrap(input), opts)
  end

  @impl true
  def stream(%__MODULE__{runnable: runnable}, input, opts) do
    Runnable.stream(%MapRunnable{runnable: runnable}, List.wrap(input), opts)
  end
end
