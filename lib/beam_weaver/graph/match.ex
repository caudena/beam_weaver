defmodule BeamWeaver.Graph.Match do
  @moduledoc false

  @spec match?(term(), term(), map()) :: boolean()
  def match?(nil, _output, _state), do: true
  def match?(true, _output, _state), do: true
  def match?(false, _output, _state), do: false

  def match?(predicate, output, _state) when is_function(predicate, 1),
    do: predicate.(output) == true

  def match?(predicate, output, state) when is_function(predicate, 2),
    do: predicate.(output, state) == true

  def match?(expected, output, state) when is_list(expected) do
    if Keyword.keyword?(expected),
      do: match?(Map.new(expected), output, state),
      else: output in expected
  end

  def match?(%Range{} = range, output, _state), do: output in range

  def match?(expected, output, state) when is_map(expected) and not is_struct(expected) do
    output_map?(output) and
      Enum.all?(expected, fn {key, expected_value} ->
        case fetch_key(output, key) do
          {:ok, value} -> value_match?(expected_value, value, state)
          :error -> false
        end
      end)
  end

  def match?(expected, output, _state), do: expected == output

  defp value_match?(expected, value, _state) when is_function(expected, 1),
    do: expected.(value) == true

  defp value_match?(expected, value, state) when is_function(expected, 2),
    do: expected.(value, state) == true

  defp value_match?(%Range{} = range, value, _state), do: value in range

  defp value_match?(expected, value, state) when is_list(expected) do
    if Keyword.keyword?(expected),
      do: value_match?(Map.new(expected), value, state),
      else: value in expected
  end

  defp value_match?(expected, value, state) when is_map(expected) and not is_struct(expected),
    do: match?(expected, value, state)

  defp value_match?(expected, value, _state), do: expected == value

  defp output_map?(output), do: is_map(output) and not is_struct(output)

  defp fetch_key(map, key) when is_map(map) do
    cond do
      Map.has_key?(map, key) ->
        {:ok, Map.fetch!(map, key)}

      is_atom(key) and Map.has_key?(map, to_string(key)) ->
        {:ok, Map.fetch!(map, to_string(key))}

      is_binary(key) ->
        case existing_atom(key) do
          nil ->
            :error

          atom ->
            if Map.has_key?(map, atom), do: {:ok, Map.fetch!(map, atom)}, else: :error
        end

      true ->
        :error
    end
  end

  defp existing_atom(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> nil
  end
end
