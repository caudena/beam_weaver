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
    deep_subtract(normalize(left), normalize(right))
  end

  defp zero, do: %{input_tokens: 0, output_tokens: 0, total_tokens: 0}

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

  defp deep_subtract(left, right) do
    keys = Enum.uniq(Map.keys(left) ++ Map.keys(right))

    Map.new(keys, fn key ->
      a = Map.get(left, key)
      b = Map.get(right, key)

      {key, subtract_value(a, b)}
    end)
  end

  defp subtract_value(a, b) when is_map(a) and is_map(b), do: deep_subtract(a, b)
  defp subtract_value(a, _b) when is_map(a), do: a
  defp subtract_value(_a, b) when is_map(b), do: deep_subtract(%{}, b)
  defp subtract_value(a, b), do: max((a || 0) - (b || 0), 0)
end
