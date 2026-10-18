defmodule BeamWeaver.VectorStore.Scoring do
  @moduledoc false

  # Each vector is divided by its largest absolute component first, which
  # leaves the cosine unchanged but keeps the squares from overflowing.
  def cosine(left, right) do
    with {:ok, left} <- normalize_vector(left),
         {:ok, right} <- normalize_vector(right),
         true <- length(left) == length(right),
         {:ok, left} <- scale(left),
         {:ok, right} <- scale(right) do
      dot = left |> Enum.zip(right) |> Enum.reduce(0.0, fn {a, b}, acc -> acc + a * b end)
      dot / (norm(left) * norm(right))
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

  # An integer too large for a float raises.
  defp normalize_vector(values) when is_list(values) do
    if Enum.all?(values, &is_number/1), do: {:ok, Enum.map(values, &(&1 * 1.0))}, else: :error
  rescue
    ArithmeticError -> :error
  end

  defp normalize_vector(_values), do: :error

  # A zero vector has no direction, so it has no cosine.
  defp scale(vector) do
    largest = vector |> Enum.map(&abs/1) |> Enum.max(fn -> 0.0 end)
    if largest == 0.0, do: :error, else: {:ok, Enum.map(vector, &(&1 / largest))}
  end

  defp norm(vector), do: vector |> Enum.reduce(0.0, fn value, acc -> acc + value * value end) |> :math.sqrt()
end
