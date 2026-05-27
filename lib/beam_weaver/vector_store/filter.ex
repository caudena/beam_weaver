defmodule BeamWeaver.VectorStore.Filter do
  @moduledoc false

  import Kernel, except: [match?: 2]

  alias BeamWeaver.Core.Error

  @operators [
    :eq,
    "eq",
    "$eq",
    :ne,
    "ne",
    "$ne",
    :in,
    "in",
    "$in",
    :nin,
    "nin",
    "$nin",
    :gt,
    "gt",
    "$gt",
    :gte,
    "gte",
    "$gte",
    :lt,
    "lt",
    "$lt",
    :lte,
    "lte",
    "$lte",
    :contain,
    "contain",
    "$contain",
    :like,
    "like",
    "$like"
  ]

  def match?(_metadata, filter) when filter in [%{}, nil], do: true

  def match?(metadata, %{"$and" => filters}) when is_list(filters),
    do: Enum.all?(filters, fn filter -> match?(metadata, filter) end)

  def match?(metadata, %{and: filters}) when is_list(filters),
    do: Enum.all?(filters, fn filter -> match?(metadata, filter) end)

  def match?(metadata, %{"$or" => filters}) when is_list(filters),
    do: Enum.any?(filters, fn filter -> match?(metadata, filter) end)

  def match?(metadata, %{or: filters}) when is_list(filters),
    do: Enum.any?(filters, fn filter -> match?(metadata, filter) end)

  def match?(metadata, %{"$not" => filter}) when is_map(filter),
    do: not match?(metadata, filter)

  def match?(metadata, %{not: filter}) when is_map(filter),
    do: not match?(metadata, filter)

  def match?(metadata, filter) when is_map(metadata) and is_map(filter) do
    Enum.all?(filter, fn {path, expected} ->
      match_condition?(get_path(metadata, path), expected)
    end)
  end

  def match?(_metadata, _filter), do: false

  def to_sql(filter, start_index \\ 1)
  def to_sql(filter, _start_index) when filter in [%{}, nil], do: {:ok, {"TRUE", []}}

  def to_sql(filter, start_index) when is_map(filter) do
    Enum.reduce_while(filter, {:ok, {[], [], start_index}}, fn {path, condition}, {:ok, {clauses, params, index}} ->
      case condition_sql(path, condition, index) do
        {:ok, {clause, new_params, next_index}} ->
          {:cont, {:ok, {[clause | clauses], params ++ new_params, next_index}}}

        {:error, error} ->
          {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, {clauses, params, _index}} ->
        {:ok, {Enum.reverse(clauses) |> Enum.join(" AND "), params}}

      other ->
        other
    end
  end

  def to_sql(_filter, _start_index),
    do: {:error, Error.new(:unsupported_vector_filter, "metadata filter must be a map")}

  defp match_condition?(actual, condition) when is_map(condition) do
    if operator_map?(condition) do
      Enum.all?(condition, fn {operator, expected} -> compare(operator, actual, expected) end)
    else
      actual == condition
    end
  end

  defp match_condition?(actual, expected), do: actual == expected

  defp compare(operator, actual, expected) when operator in [:eq, "eq", "$eq"],
    do: actual == expected

  defp compare(operator, actual, expected) when operator in [:ne, "ne", "$ne"],
    do: actual != expected

  defp compare(operator, actual, expected) when operator in [:in, "in"] and is_list(expected),
    do: actual in expected

  defp compare(operator, actual, expected) when operator in ["$in"] and is_list(expected),
    do: actual in expected

  defp compare(operator, actual, expected) when operator in [:nin, "nin"] and is_list(expected),
    do: actual not in expected

  defp compare(operator, actual, expected) when operator in ["$nin"] and is_list(expected),
    do: actual not in expected

  defp compare(operator, actual, expected) when operator in [:gt, "gt", "$gt"],
    do: numeric_compare(actual, expected, &>/2)

  defp compare(operator, actual, expected) when operator in [:gte, "gte", "$gte"],
    do: numeric_compare(actual, expected, &>=/2)

  defp compare(operator, actual, expected) when operator in [:lt, "lt", "$lt"],
    do: numeric_compare(actual, expected, &</2)

  defp compare(operator, actual, expected) when operator in [:lte, "lte", "$lte"],
    do: numeric_compare(actual, expected, &<=/2)

  defp compare(operator, actual, expected) when operator in [:contain, "contain", "$contain"] do
    cond do
      is_binary(actual) -> String.contains?(actual, to_string(expected))
      is_list(actual) -> expected in actual
      true -> false
    end
  end

  defp compare(operator, actual, expected) when operator in [:like, "like", "$like"] do
    if is_binary(actual), do: like_match?(actual, to_string(expected)), else: false
  end

  defp compare(_operator, _actual, _expected), do: false

  defp numeric_compare(actual, expected, fun) when is_number(actual) and is_number(expected),
    do: fun.(actual, expected)

  defp numeric_compare(_actual, _expected, _fun), do: false

  defp condition_sql(path, condition, index) when is_map(condition) do
    if operator_map?(condition) do
      operator_sql(path, condition, index)
    else
      {:error,
       Error.new(
         :unsupported_vector_filter,
         "nested metadata object equality is not supported",
         %{
           path: path
         }
       )}
    end
  end

  defp condition_sql(path, condition, index), do: equality_sql(path, condition, index)

  defp equality_sql(path, value, index) do
    {:ok, {"#{json_path(path)} = $#{index}", [to_string(value)], index + 1}}
  end

  defp operator_sql(path, condition, index) do
    Enum.reduce_while(condition, {:ok, {[], [], index}}, fn {operator, expected}, {:ok, {clauses, params, current}} ->
      case single_operator_sql(path, operator, expected, current) do
        {:ok, {clause, new_params, next}} ->
          {:cont, {:ok, {[clause | clauses], params ++ new_params, next}}}

        {:error, error} ->
          {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, {clauses, params, next}} ->
        {:ok, {Enum.reverse(clauses) |> Enum.join(" AND "), params, next}}

      other ->
        other
    end
  end

  defp single_operator_sql(path, operator, expected, index)
       when operator in [:eq, "eq", "$eq"] do
    equality_sql(path, expected, index)
  end

  defp single_operator_sql(path, operator, expected, index)
       when operator in [:ne, "ne", "$ne"] do
    {:ok, {"#{json_path(path)} != $#{index}", [to_string(expected)], index + 1}}
  end

  defp single_operator_sql(path, operator, expected, index)
       when operator in [:in, "in", "$in"] and is_list(expected) do
    {:ok, {"#{json_path(path)} = ANY($#{index})", [Enum.map(expected, &to_string/1)], index + 1}}
  end

  defp single_operator_sql(path, operator, expected, index)
       when operator in [:nin, "nin", "$nin"] and is_list(expected) do
    {:ok, {"NOT (#{json_path(path)} = ANY($#{index}))", [Enum.map(expected, &to_string/1)], index + 1}}
  end

  defp single_operator_sql(path, operator, expected, index)
       when operator in [:gt, "gt", "$gt"] and is_number(expected),
       do: numeric_sql(path, ">", expected, index)

  defp single_operator_sql(path, operator, expected, index)
       when operator in [:gte, "gte", "$gte"] and is_number(expected),
       do: numeric_sql(path, ">=", expected, index)

  defp single_operator_sql(path, operator, expected, index)
       when operator in [:lt, "lt", "$lt"] and is_number(expected),
       do: numeric_sql(path, "<", expected, index)

  defp single_operator_sql(path, operator, expected, index)
       when operator in [:lte, "lte", "$lte"] and is_number(expected),
       do: numeric_sql(path, "<=", expected, index)

  defp single_operator_sql(path, operator, expected, index)
       when operator in [:contain, "contain", "$contain", :like, "like", "$like"] do
    {:ok, {"#{json_path(path)} ILIKE $#{index}", ["%#{to_string(expected)}%"], index + 1}}
  end

  defp single_operator_sql(_path, operator, _expected, _index),
    do:
      {:error,
       Error.new(:unsupported_vector_filter, "unsupported metadata filter operator", %{
         operator: operator
       })}

  defp numeric_sql(path, op, value, index) do
    {:ok, {"(#{json_path(path)})::numeric #{op} $#{index}", [value], index + 1}}
  end

  defp operator_map?(map), do: Enum.any?(Map.keys(map), &(&1 in @operators))

  defp get_path(metadata, path) do
    path
    |> path_segments()
    |> Enum.reduce_while(metadata, fn segment, current ->
      cond do
        is_map(current) and Map.has_key?(current, segment) ->
          {:cont, Map.fetch!(current, segment)}

        is_map(current) and Map.has_key?(current, to_string(segment)) ->
          {:cont, Map.fetch!(current, to_string(segment))}

        is_map(current) ->
          case Enum.find(Map.keys(current), &(to_string(&1) == to_string(segment))) do
            nil -> {:halt, nil}
            key -> {:cont, Map.fetch!(current, key)}
          end

        true ->
          {:halt, nil}
      end
    end)
  end

  defp json_path(path) do
    segments =
      path
      |> path_segments()
      |> Enum.map_join(",", &to_string/1)

    "metadata #>> '{#{segments}}'"
  end

  defp path_segments(path) when is_list(path), do: path

  defp path_segments(path) when is_binary(path) do
    if String.contains?(path, "."), do: String.split(path, "."), else: [path]
  end

  defp path_segments(path), do: [path]

  defp like_match?(actual, pattern) do
    pattern =
      pattern
      |> Regex.escape()
      |> String.replace("%", ".*")
      |> String.replace("_", ".")

    Regex.match?(~r/^#{pattern}$/iu, actual) or String.contains?(actual, pattern)
  rescue
    _exception -> false
  end
end
