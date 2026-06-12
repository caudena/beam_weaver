defmodule BeamWeaver.VectorStore.Scoring do
  @moduledoc false

  alias BeamWeaver.Core.Error

  @spec cosine_similarity(list(), list()) :: {:ok, [[float()]]} | {:error, Error.t()}
  def cosine_similarity(left_matrix, right_matrix) do
    with {:ok, left_rows} <- normalize_matrix(left_matrix, :left),
         {:ok, right_rows} <- normalize_matrix(right_matrix, :right),
         {:ok, dimensions} <- validate_dimensions(left_rows, right_rows),
         :ok <- validate_non_zero_rows(left_rows ++ right_rows, dimensions) do
      cond do
        left_rows == [] ->
          {:ok, [[]]}

        right_rows == [] ->
          {:ok, Enum.map(left_rows, fn _row -> [] end)}

        true ->
          {:ok,
           Enum.map(left_rows, fn left ->
             Enum.map(right_rows, fn right ->
               {:ok, score} = cosine_pair(left, right)
               score
             end)
           end)}
      end
    end
  end

  def cosine(left, right) do
    case cosine_pair(left, right) do
      {:ok, score} -> score
      {:error, _error} -> 0
    end
  end

  def mmr(_query_vector, _candidates, 0, _lambda, selected), do: Enum.reverse(selected)
  def mmr(_query_vector, [], _k, _lambda, selected), do: Enum.reverse(selected)

  def mmr(query_vector, candidates, k, lambda, selected) do
    {best_doc, _best_vector, _score} =
      Enum.max_by(candidates, fn {_doc, vector, score} ->
        diversity =
          selected
          |> Enum.map(fn {_selected_doc, selected_vector, _score} ->
            cosine(vector, selected_vector)
          end)
          |> Enum.max(fn -> 0 end)

        lambda * score - (1 - lambda) * diversity + cosine(query_vector, vector) * 0.0
      end)

    remaining = Enum.reject(candidates, fn {doc, _vector, _score} -> doc == best_doc end)
    selected_entry = Enum.find(candidates, fn {doc, _vector, _score} -> doc == best_doc end)
    mmr(query_vector, remaining, k - 1, lambda, [selected_entry | selected])
  end

  defp cosine_pair(left, right) do
    with {:ok, left} <- normalize_vector(left),
         {:ok, right} <- normalize_vector(right),
         :ok <- same_dimension(left, right),
         {:ok, left_norm} <- norm(left),
         {:ok, right_norm} <- norm(right),
         :ok <- non_zero_norm(left_norm),
         :ok <- non_zero_norm(right_norm) do
      dot = left |> Enum.zip(right) |> Enum.reduce(0.0, fn {a, b}, acc -> acc + a * b end)
      {:ok, dot / (left_norm * right_norm)}
    end
  end

  defp normalize_matrix(rows, side) when is_list(rows) do
    rows
    |> Enum.reduce_while({:ok, []}, fn row, {:ok, acc} ->
      case normalize_vector(row) do
        {:ok, vector} ->
          {:cont, {:ok, [vector | acc]}}

        {:error, %Error{} = error} ->
          {:halt, {:error, %{error | details: Map.put(error.details, :side, side)}}}
      end
    end)
    |> case do
      {:ok, vectors} -> {:ok, Enum.reverse(vectors)}
      error -> error
    end
  end

  defp normalize_matrix(_rows, side) do
    {:error, Error.new(:invalid_vector_matrix, "vector matrix must be a list", %{side: side})}
  end

  defp normalize_vector(values) when is_tuple(values),
    do: values |> Tuple.to_list() |> normalize_vector()

  defp normalize_vector(values) when is_list(values) do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      if finite_number?(value) do
        {:cont, {:ok, [value * 1.0 | acc]}}
      else
        {:halt,
         {:error,
          Error.new(:invalid_vector, "vector values must be finite numbers", %{
            value: inspect(value)
          })}}
      end
    end)
    |> case do
      {:ok, vector} -> {:ok, Enum.reverse(vector)}
      error -> error
    end
  end

  defp normalize_vector(_values) do
    {:error, Error.new(:invalid_vector, "vector must be a list or tuple")}
  end

  defp validate_dimensions([], _right_rows), do: {:ok, 0}
  defp validate_dimensions(_left_rows, []), do: {:ok, 0}

  defp validate_dimensions([first_left | _] = left_rows, right_rows) do
    dimensions = length(first_left)

    cond do
      Enum.any?(left_rows, &(length(&1) != dimensions)) ->
        {:error, Error.new(:dimension_mismatch, "Number of columns in X and Y must be the same")}

      Enum.any?(right_rows, &(length(&1) != dimensions)) ->
        {:error, Error.new(:dimension_mismatch, "Number of columns in X and Y must be the same")}

      true ->
        {:ok, dimensions}
    end
  end

  defp same_dimension(left, right) when length(left) == length(right), do: :ok

  defp same_dimension(_left, _right),
    do: {:error, Error.new(:dimension_mismatch, "Number of columns in X and Y must be the same")}

  defp validate_non_zero_rows(_rows, 0), do: :ok

  defp validate_non_zero_rows(rows, _dimensions) do
    if Enum.any?(rows, &(norm_value(&1) == 0.0)) do
      {:error, Error.new(:invalid_vector, "NaN values found from zero-length vector norm")}
    else
      :ok
    end
  end

  defp norm(vector) do
    value = norm_value(vector)

    if finite_number?(value),
      do: {:ok, value},
      else: {:error, Error.new(:invalid_vector, "NaN values found in cosine similarity")}
  end

  defp norm_value(vector) do
    vector
    |> Enum.reduce(0.0, fn value, acc -> acc + value * value end)
    |> :math.sqrt()
  end

  defp non_zero_norm(norm) when norm == 0.0,
    do: {:error, Error.new(:invalid_vector, "NaN values found from zero-length vector norm")}

  defp non_zero_norm(_norm), do: :ok

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
