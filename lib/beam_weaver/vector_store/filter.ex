defmodule BeamWeaver.VectorStore.Filter do
  @moduledoc false

  import Kernel, except: [match?: 2]

  alias BeamWeaver.Core.Error

  # Each operator is spelled as an atom, a string, or a string with `$`.
  @operators for name <- ~w(eq ne in nin gt gte lt lte contain like),
                 key <- [String.to_atom(name), name, "$" <> name],
                 into: %{},
                 do: {key, String.to_atom(name)}

  def match?(_metadata, filter) when filter in [%{}, nil], do: true

  def match?(metadata, filter) do
    case logical(filter) do
      {:and, filters} ->
        Enum.all?(filters, &match?(metadata, &1))

      {:or, filters} ->
        Enum.any?(filters, &match?(metadata, &1))

      {:not, filter} ->
        not match?(metadata, filter)

      nil when is_map(metadata) and is_map(filter) ->
        Enum.all?(filter, fn {path, expected} -> match_condition?(get_path(metadata, path), expected) end)

      nil ->
        false
    end
  end

  def to_sql(filter, _start_index) when filter in [%{}, nil], do: {:ok, {"TRUE", []}}

  def to_sql(filter, start_index) when is_map(filter) do
    case logical(filter) do
      {:and, filters} ->
        combine_sql(filters, start_index, "AND", "TRUE")

      {:or, filters} ->
        combine_sql(filters, start_index, "OR", "FALSE")

      {:not, filter} ->
        with {:ok, {clause, params}} <- to_sql(filter, start_index), do: {:ok, {"NOT (#{clause})", params}}

      nil ->
        with {:ok, clauses, params, _next} <-
               each_sql(filter, start_index, fn {path, condition}, index -> condition_sql(path, condition, index) end),
             do: {:ok, {Enum.join(clauses, " AND "), params}}
    end
  end

  def to_sql(_filter, _start_index),
    do: {:error, Error.new(:unsupported_vector_filter, "metadata filter must be a map")}

  defp logical(%{"$and" => filters}) when is_list(filters), do: {:and, filters}
  defp logical(%{and: filters}) when is_list(filters), do: {:and, filters}
  defp logical(%{"$or" => filters}) when is_list(filters), do: {:or, filters}
  defp logical(%{or: filters}) when is_list(filters), do: {:or, filters}
  defp logical(%{"$not" => filter}) when is_map(filter), do: {:not, filter}
  defp logical(%{not: filter}) when is_map(filter), do: {:not, filter}
  defp logical(_filter), do: nil

  defp combine_sql(filters, start_index, joiner, empty_sql) do
    with {:ok, clauses, params, _next} <-
           each_sql(filters, start_index, fn filter, index ->
             with {:ok, {clause, params}} <- to_sql(filter, index), do: {:ok, {clause, params, index + length(params)}}
           end) do
      if clauses == [],
        do: {:ok, {empty_sql, []}},
        else: {:ok, {Enum.map_join(clauses, " #{joiner} ", &"(#{&1})"), params}}
    end
  end

  # Renders each entry with `fun`, which gets the next free parameter index,
  # and collects the clauses and parameters in order.
  defp each_sql(entries, index, fun) do
    Enum.reduce_while(entries, {:ok, [], [], index}, fn entry, {:ok, clauses, params, index} ->
      case fun.(entry, index) do
        {:ok, {clause, new_params, next}} -> {:cont, {:ok, clauses ++ [clause], params ++ new_params, next}}
        error -> {:halt, error}
      end
    end)
  end

  defp match_condition?(actual, condition) when is_map(condition) do
    if operator_map?(condition),
      do: Enum.all?(condition, fn {operator, expected} -> compare(@operators[operator], actual, expected) end),
      else: actual == condition
  end

  defp match_condition?(actual, expected), do: actual == expected

  defp compare(:eq, actual, expected), do: actual == expected
  defp compare(:ne, actual, expected), do: actual != expected
  defp compare(:in, actual, expected) when is_list(expected), do: actual in expected
  defp compare(:nin, actual, expected) when is_list(expected), do: actual not in expected
  defp compare(:gt, actual, expected), do: numeric_compare(actual, expected, &>/2)
  defp compare(:gte, actual, expected), do: numeric_compare(actual, expected, &>=/2)
  defp compare(:lt, actual, expected), do: numeric_compare(actual, expected, &</2)
  defp compare(:lte, actual, expected), do: numeric_compare(actual, expected, &<=/2)
  # Postgres ILIKE also lowercases both sides to ignore case.
  defp compare(:contain, actual, expected) when is_binary(actual),
    do: String.contains?(String.downcase(actual), String.downcase(to_string(expected)))

  defp compare(:contain, actual, expected) when is_list(actual), do: expected in actual
  defp compare(:like, actual, expected) when is_binary(actual), do: like_match?(actual, to_string(expected))
  defp compare(_operator, _actual, _expected), do: false

  defp numeric_compare(actual, expected, fun) when is_number(actual) and is_number(expected),
    do: fun.(actual, expected)

  defp numeric_compare(_actual, _expected, _fun), do: false

  defp condition_sql(path, condition, index) when is_map(condition) do
    if operator_map?(condition) do
      with {:ok, clauses, params, next} <-
             each_sql(condition, index, fn {operator, expected}, index ->
               single_operator_sql(path, operator, expected, index)
             end),
           do: {:ok, {Enum.join(clauses, " AND "), params, next}}
    else
      {:error, Error.new(:unsupported_vector_filter, "nested metadata object equality is not supported", %{path: path})}
    end
  end

  defp condition_sql(path, condition, index), do: equality_sql(path, condition, index)

  defp equality_sql(path, value, index), do: json_path(path, index, to_string(value), &"#{&1} = #{&2}")

  defp single_operator_sql(path, operator, expected, index) do
    operator_sql(path, @operators[operator], expected, index) ||
      {:error, Error.new(:unsupported_vector_filter, "unsupported metadata filter operator", %{operator: operator})}
  end

  defp operator_sql(path, :eq, expected, index), do: equality_sql(path, expected, index)
  defp operator_sql(path, :ne, expected, index), do: json_path(path, index, to_string(expected), &"#{&1} != #{&2}")

  defp operator_sql(path, :in, expected, index) when is_list(expected),
    do: json_path(path, index, Enum.map(expected, &to_string/1), &"#{&1} = ANY(#{&2})")

  defp operator_sql(path, :nin, expected, index) when is_list(expected),
    do: json_path(path, index, Enum.map(expected, &to_string/1), &"NOT (#{&1} = ANY(#{&2}))")

  defp operator_sql(path, :gt, expected, index) when is_number(expected), do: numeric_sql(path, ">", expected, index)
  defp operator_sql(path, :gte, expected, index) when is_number(expected), do: numeric_sql(path, ">=", expected, index)
  defp operator_sql(path, :lt, expected, index) when is_number(expected), do: numeric_sql(path, "<", expected, index)
  defp operator_sql(path, :lte, expected, index) when is_number(expected), do: numeric_sql(path, "<=", expected, index)

  # A substring of a string value, taken literally, or an element of an array value.
  defp operator_sql(path, :contain, expected, index) do
    pattern = "%#{like_escape(to_string(expected))}%"
    array = "WHEN 'array' THEN metadata #> $#{index}::text[] @> $#{index + 2}::jsonb "
    {:ok, {string_ilike_sql(index, array), [text_path(path), pattern, [expected]], index + 3}}
  end

  defp operator_sql(path, :like, expected, index),
    do: {:ok, {string_ilike_sql(index, ""), [text_path(path), to_string(expected)], index + 2}}

  defp operator_sql(_path, _operator, _expected, _index), do: nil

  # `#>>` gives a number, boolean, array or object as its JSON text, so ILIKE
  # applies to string values only.
  defp string_ilike_sql(index, other_cases) do
    "CASE jsonb_typeof(metadata #> $#{index}::text[]) " <>
      "WHEN 'string' THEN metadata #>> $#{index}::text[] ILIKE $#{index + 1} #{other_cases}ELSE FALSE END"
  end

  # Backslash is the default LIKE escape character.
  defp like_escape(value), do: String.replace(value, ["\\", "%", "_"], &("\\" <> &1))

  defp numeric_sql(path, op, value, index), do: json_path(path, index, value, &"(#{&1})::numeric #{op} #{&2}")

  defp operator_map?(map), do: Enum.any?(Map.keys(map), &Map.has_key?(@operators, &1))

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

  defp json_path(path, index, value, render),
    do: {:ok, {render.("metadata #>> $#{index}::text[]", "$#{index + 1}"), [text_path(path), value], index + 2}}

  defp text_path(path), do: path |> path_segments() |> Enum.map(&to_string/1)

  defp path_segments(path) when is_list(path), do: path
  defp path_segments(path) when is_binary(path), do: String.split(path, ".")
  defp path_segments(path), do: [path]

  # As SQL ILIKE: the whole value, ignoring case, where `%` is any run of
  # characters, `_` is one character, and a backslash makes the character
  # after it literal. A pattern that ends in a backslash, or a value that
  # isn't UTF-8, matches nothing.
  defp like_match?(actual, pattern) do
    with {:ok, source} <- like_regex(String.codepoints(pattern), []),
         {:ok, regex} <- Regex.compile("\\A#{source}\\z", "isu") do
      Regex.match?(regex, actual)
    else
      _error -> false
    end
  rescue
    _exception -> false
  end

  defp like_regex([], acc), do: {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary()}
  defp like_regex(["\\"], _acc), do: :error
  defp like_regex(["\\", char | rest], acc), do: like_regex(rest, [Regex.escape(char) | acc])
  defp like_regex(["%" | rest], acc), do: like_regex(rest, [".*" | acc])
  defp like_regex(["_" | rest], acc), do: like_regex(rest, ["." | acc])
  defp like_regex([char | rest], acc), do: like_regex(rest, [Regex.escape(char) | acc])
end
