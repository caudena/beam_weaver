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

  def match?([], output, _state), do: output in []

  def match?(expected, output, state) when is_list(expected) do
    if Keyword.keyword?(expected),
      do: match?(Map.new(expected), output, state),
      else: output in expected
  end

  def match?(%Range{} = range, output, _state), do: output in range

  def match?(expected, output, state) when is_map(expected) and not is_struct(expected) do
    output_map?(output) and
      Enum.all?(expected, fn {key, expected_value} ->
        case BeamWeaver.MapAccess.fetch(output, key) do
          {:ok, value} -> value_match?(expected_value, value, state)
          :error -> false
        end
      end)
  end

  def match?(expected, output, _state), do: expected == output

  # A value of a map pattern matches as a whole pattern does, except that
  # `nil`, `true` and `false` match only themselves.
  defp value_match?(expected, value, _state) when is_boolean(expected) or is_nil(expected), do: expected == value
  defp value_match?(expected, value, state), do: match?(expected, value, state)

  defp output_map?(output), do: is_map(output) and not is_struct(output)
end
