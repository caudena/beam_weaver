defmodule BeamWeaver.Result do
  @moduledoc false

  @spec traverse(Enumerable.t(), (term() -> {:ok, term()} | {:error, term()})) ::
          {:ok, [term()]} | {:error, term()}
  def traverse(enumerable, fun) when is_function(fun, 1) do
    result =
      Enum.reduce_while(enumerable, {:ok, []}, fn value, {:ok, acc} ->
        case fun.(value) do
          {:ok, mapped} -> {:cont, {:ok, [mapped | acc]}}
          {:error, error} -> {:halt, {:error, error}}
        end
      end)

    with {:ok, values} <- result, do: {:ok, Enum.reverse(values)}
  end

  @spec flat_traverse(Enumerable.t(), (term() -> {:ok, Enumerable.t()} | {:error, term()})) ::
          {:ok, [term()]} | {:error, term()}
  def flat_traverse(enumerable, fun) when is_function(fun, 1) do
    with {:ok, values} <- traverse(enumerable, fun), do: {:ok, Enum.flat_map(values, &List.wrap/1)}
  end

  @spec collect(Enumerable.t()) :: {:ok, [term()]} | {:error, term()}
  def collect(results), do: traverse(results, & &1)
end
