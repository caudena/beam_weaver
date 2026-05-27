defmodule BeamWeaver.Result do
  @moduledoc false

  @spec traverse(Enumerable.t(), (term() -> {:ok, term()} | {:error, term()})) ::
          {:ok, [term()]} | {:error, term()}
  def traverse(enumerable, fun) when is_function(fun, 1) do
    enumerable
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      case fun.(value) do
        {:ok, mapped} -> {:cont, {:ok, [mapped | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      {:error, error} -> {:error, error}
    end
  end

  @spec flat_traverse(Enumerable.t(), (term() -> {:ok, Enumerable.t()} | {:error, term()})) ::
          {:ok, [term()]} | {:error, term()}
  def flat_traverse(enumerable, fun) when is_function(fun, 1) do
    enumerable
    |> traverse(fun)
    |> case do
      {:ok, values} -> {:ok, Enum.flat_map(values, &List.wrap/1)}
      {:error, error} -> {:error, error}
    end
  end

  @spec collect(Enumerable.t()) :: {:ok, [term()]} | {:error, term()}
  def collect(results), do: traverse(results, & &1)
end
