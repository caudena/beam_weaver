defmodule BeamWeaver.Runnable.Sequence do
  @moduledoc false

  @behaviour BeamWeaver.Runnable

  alias BeamWeaver.Runnable

  defstruct steps: [], name: nil

  @impl true
  def invoke(%__MODULE__{steps: steps}, input, opts) do
    Enum.reduce_while(steps, {:ok, input}, fn step, {:ok, acc} ->
      case Runnable.invoke(step, acc, opts) do
        {:ok, output} -> {:cont, {:ok, output}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  @impl true
  def stream(%__MODULE__{} = sequence, input, opts) do
    case split_last(sequence.steps) do
      {[], nil} ->
        {:ok, [input]}

      {prefix, last} ->
        prefix = %__MODULE__{steps: prefix, name: sequence.name}

        with {:ok, intermediate} <- invoke(prefix, input, opts) do
          Runnable.stream(last, intermediate, opts)
        end
    end
  end

  @impl true
  def transform(%__MODULE__{steps: []}, input, _opts), do: {:ok, input}

  def transform(%__MODULE__{steps: [first | rest]}, input, opts) do
    with {:ok, stream} <- Runnable.transform(first, input, opts) do
      Enum.reduce_while(rest, {:ok, stream}, fn step, {:ok, acc} ->
        case Runnable.transform(step, acc, opts) do
          {:ok, next} -> {:cont, {:ok, next}}
          {:error, error} -> {:halt, {:error, error}}
        end
      end)
    end
  end

  defp split_last([]), do: {[], nil}

  defp split_last(steps) do
    {Enum.drop(steps, -1), List.last(steps)}
  end
end
