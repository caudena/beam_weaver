defmodule BeamWeaver.Core.Messages.Usage do
  @moduledoc false

  @spec add(map() | nil, map() | nil) :: map()
  def add(nil, nil), do: zero()
  def add(nil, right), do: normalize(right)
  def add(left, nil), do: normalize(left)

  def add(left, right) when is_map(left) and is_map(right) do
    deep_merge(normalize(left), normalize(right), &Kernel.+/2)
  end

  @spec subtract(map() | nil, map() | nil) :: map()
  def subtract(nil, nil), do: zero()
  def subtract(left, nil), do: normalize(left)
  def subtract(nil, right), do: subtract(zero(), right)

  def subtract(left, right) when is_map(left) and is_map(right) do
    deep_merge(normalize(left), normalize(right), fn a, b -> max(a - b, 0) end)
  end

  defp zero, do: %{input_tokens: 0, output_tokens: 0, total_tokens: 0}

  defp normalize(nil), do: zero()
  defp normalize(usage) when is_map(usage), do: usage

  defp deep_merge(left, right, numeric_fun) do
    Map.merge(left, right, fn _key, a, b ->
      cond do
        is_number(a) and is_number(b) ->
          numeric_fun.(a, b)

        is_map(a) and is_map(b) ->
          deep_merge(a, b, numeric_fun)

        is_nil(a) ->
          b

        true ->
          a
      end
    end)
  end
end
