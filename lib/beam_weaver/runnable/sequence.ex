defmodule BeamWeaver.Runnable.Sequence do
  @moduledoc false

  @behaviour BeamWeaver.Runnable

  alias BeamWeaver.Runnable

  defstruct steps: [], name: nil

  @impl true
  def invoke(%__MODULE__{steps: steps}, input, opts), do: pipe(steps, input, &Runnable.invoke(&1, &2, opts))

  @impl true
  def stream(%__MODULE__{steps: []}, input, _opts), do: {:ok, [input]}

  def stream(%__MODULE__{} = sequence, input, opts) do
    {prefix, [last]} = Enum.split(sequence.steps, -1)

    with {:ok, intermediate} <- invoke(%{sequence | steps: prefix}, input, opts) do
      Runnable.stream(last, intermediate, opts)
    end
  end

  @impl true
  def transform(%__MODULE__{steps: steps}, input, opts), do: pipe(steps, input, &Runnable.transform(&1, &2, opts))

  defp pipe(steps, input, run) do
    Enum.reduce_while(steps, {:ok, input}, fn step, {:ok, acc} ->
      case run.(step, acc) do
        {:ok, output} -> {:cont, {:ok, output}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end
end
