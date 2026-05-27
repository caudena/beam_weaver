defmodule BeamWeaver.Runnable.Assign do
  @moduledoc false

  @behaviour BeamWeaver.Runnable

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Runnable

  defstruct base: nil, assignments: %{}

  @impl true
  def invoke(%__MODULE__{base: base, assignments: assignments}, input, opts) do
    with {:ok, base_value} <- Runnable.invoke(base || Runnable.passthrough(), input, opts),
         true <-
           is_map(base_value) ||
             {:error, Error.new(:invalid_runnable_input, "assign requires a map input")} do
      Enum.reduce_while(assignments, {:ok, base_value}, fn {key, runnable}, {:ok, acc} ->
        case Runnable.invoke(runnable, input, opts) do
          {:ok, value} -> {:cont, {:ok, Map.put(acc, key, value)}}
          {:error, error} -> {:halt, {:error, error}}
        end
      end)
    end
  end
end
