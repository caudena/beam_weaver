defmodule BeamWeaver.VectorStore.Scoring do
  @moduledoc false

  def cosine(left, right) do
    with {:ok, left} <- normalize_vector(left),
         {:ok, right} <- normalize_vector(right),
         true <- length(left) == length(right),
         left_norm when left_norm != 0.0 <- norm(left),
         right_norm when right_norm != 0.0 <- norm(right) do
      dot = left |> Enum.zip(right) |> Enum.reduce(0.0, fn {a, b}, acc -> acc + a * b end)
      dot / (left_norm * right_norm)
    else
      _error -> 0
    end
  end

  def mmr(candidates, k, lambda), do: mmr(candidates, k, lambda, [])

  defp mmr(_candidates, 0, _lambda, selected), do: Enum.reverse(selected)
  defp mmr([], _k, _lambda, selected), do: Enum.reverse(selected)

  defp mmr(candidates, k, lambda, selected) do
    {best_doc, _vector, _score} =
      best =
      Enum.max_by(candidates, fn {_doc, vector, score} ->
        diversity =
          selected
          |> Enum.map(fn {_selected_doc, selected_vector, _score} -> cosine(vector, selected_vector) end)
          |> Enum.max(fn -> 0 end)

        lambda * score - (1 - lambda) * diversity
      end)

    remaining = Enum.reject(candidates, fn {doc, _vector, _score} -> doc == best_doc end)
    mmr(remaining, k - 1, lambda, [best | selected])
  end

  defp normalize_vector(values) when is_tuple(values), do: values |> Tuple.to_list() |> normalize_vector()

  defp normalize_vector(values) when is_list(values) do
    if Enum.all?(values, &finite_number?/1), do: {:ok, Enum.map(values, &(&1 * 1.0))}, else: :error
  end

  defp normalize_vector(_values), do: :error

  defp norm(vector), do: vector |> Enum.reduce(0.0, fn value, acc -> acc + value * value end) |> :math.sqrt()

  defp finite_number?(value) when is_integer(value) do
    _float = value * 1.0
    true
  rescue
    ArithmeticError -> false
  end

  defp finite_number?(value) when is_float(value) do
    <<_sign::1, exponent::11, _mantissa::52>> = <<value::float-64>>
    exponent != 0x7FF
  end

  defp finite_number?(_value), do: false
end
