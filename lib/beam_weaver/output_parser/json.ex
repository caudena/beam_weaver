defmodule BeamWeaver.OutputParser.JSON do
  @moduledoc false

  alias BeamWeaver.Core.Error

  @spec parse(String.t(), keyword()) :: {:ok, term()} | {:error, Error.t()}
  def parse(text, opts \\ []) when is_binary(text) do
    text = String.trim(text)

    case decode_first_json_candidate(text) do
      {:ok, data} ->
        {:ok, data}

      {:error, error} ->
        cond do
          Keyword.get(opts, :partial, false) ->
            parse_partial_json(text, error)

          python_dict?(text) ->
            text |> python_dict_to_json() |> parse(Keyword.put(opts, :partial, false))

          true ->
            parser_error(:json_parser, "output was not valid JSON", %{
              reason: Exception.message(error),
              input: preview(text)
            })
        end
    end
  end

  @spec parse_partial(String.t()) :: {:ok, term()} | {:error, Error.t()}
  def parse_partial(text) when is_binary(text), do: parse(text, partial: true)

  @spec parse_markdown(String.t(), keyword()) :: {:ok, term()} | {:error, Error.t()}
  def parse_markdown(text, opts \\ []) when is_binary(text) do
    parse(text, Keyword.put_new(opts, :partial, true))
  end

  @spec parse_and_check_markdown(String.t(), [String.t() | atom()]) ::
          {:ok, map()} | {:error, Error.t()}
  def parse_and_check_markdown(text, expected_keys) when is_list(expected_keys) do
    with {:ok, %{} = data} <- parse_markdown(text),
         :ok <- require_keys(data, expected_keys) do
      {:ok, data}
    else
      {:ok, other} ->
        parser_error(:json_parser, "expected a JSON object", %{value: other})

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp require_keys(data, keys) do
    missing =
      keys
      |> Enum.map(&to_string/1)
      |> Enum.reject(&Map.has_key?(data, &1))

    if missing == [] do
      :ok
    else
      parser_error(:json_parser, "JSON object is missing required keys", %{missing: missing})
    end
  end

  defp parse_partial_json(text, original_error) do
    text
    |> json_candidates()
    |> Enum.flat_map(&partial_candidates/1)
    |> Enum.find_value(&decode_repaired_json/1) ||
      text
      |> json_candidates()
      |> Enum.find_value(&decode_repaired_json/1) ||
      parser_error(:json_parser, "partial output was not valid JSON", %{
        reason: Exception.message(original_error),
        input: preview(text)
      })
  end

  defp decode_repaired_json(candidate) do
    candidate
    |> repaired_json_candidates()
    |> Enum.find_value(fn candidate ->
      case decode_first_json_candidate(candidate) do
        {:ok, data} -> {:ok, data}
        {:error, _error} -> nil
      end
    end)
  end

  defp decode_first_json_candidate(text) do
    json_candidates(text)
    |> Enum.find_value(fn candidate ->
      case BeamWeaver.JSON.decode(candidate) do
        {:ok, data} -> {:ok, data}
        {:error, _error} -> nil
      end
    end) || BeamWeaver.JSON.decode(text)
  end

  defp json_candidates(text) do
    [
      text
      | fenced_json_candidates(text) ++
          partial_fenced_json_candidates(text) ++ bare_json_candidates(text)
    ]
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp fenced_json_candidates(text) do
    Regex.scan(~r/```(?:json)?\s*(.*?)```/s, text)
    |> Enum.map(fn [_match, candidate] -> String.trim(candidate) end)
  end

  defp partial_fenced_json_candidates(text) do
    case Regex.run(~r/```(?:json)?\s*(.*)$/s, text) do
      [_match, candidate] -> [String.trim(candidate)]
      _other -> []
    end
  end

  defp bare_json_candidates(text) do
    case Regex.run(~r/([\{\[].*)$/s, text) do
      [_match, candidate] -> [String.trim(candidate)]
      _other -> []
    end
  end

  defp partial_candidates(text) do
    graphemes = String.graphemes(text)

    0..length(graphemes)
    |> Enum.reverse()
    |> Enum.map(fn count -> Enum.take(graphemes, count) |> Enum.join() end)
  end

  defp python_dict?(text), do: Regex.match?(~r/^\s*[{[]/, text) and String.contains?(text, "'")

  defp python_dict_to_json(text) do
    text
    |> String.replace(~r/'([^']*)'/, "\"\\1\"")
    |> String.replace("None", "null")
    |> String.replace("True", "true")
    |> String.replace("False", "false")
  end

  defp repaired_json_candidates(candidate) do
    repaired = repair_json(candidate)

    [candidate, repaired]
    |> Enum.flat_map(fn value ->
      value
      |> String.graphemes()
      |> then(fn graphemes ->
        0..length(graphemes)
        |> Enum.reverse()
        |> Enum.map(fn count -> graphemes |> Enum.take(count) |> Enum.join() |> repair_json() end)
      end)
    end)
    |> Enum.uniq()
  end

  defp repair_json(candidate) do
    {out, stack, in_string, escaped} =
      candidate
      |> String.graphemes()
      |> Enum.reduce({"", [], false, false}, fn char, {out, stack, in_string, escaped} ->
        cond do
          in_string and escaped ->
            {out <> char, stack, true, false}

          in_string and char == "\\" ->
            {out <> char, stack, true, true}

          in_string and char == "\"" ->
            {out <> char, stack, false, false}

          in_string and char == "\n" ->
            {out <> "\\n", stack, true, false}

          in_string and char == "\r" ->
            {out <> "\\r", stack, true, false}

          in_string and char == "\t" ->
            {out <> "\\t", stack, true, false}

          in_string ->
            {out <> char, stack, true, false}

          char == "\"" ->
            {out <> char, stack, true, false}

          char == "{" ->
            {out <> char, ["}" | stack], false, false}

          char == "[" ->
            {out <> char, ["]" | stack], false, false}

          char in ["}", "]"] ->
            {out <> char, tl_if_matches(stack, char), false, false}

          true ->
            {out <> char, stack, false, false}
        end
      end)

    out =
      out
      |> maybe_drop_trailing_escape(in_string, escaped)
      |> trim_incomplete_json_tail()

    out = if in_string, do: out <> "\"", else: out
    out <> Enum.join(stack)
  end

  defp tl_if_matches([char | rest], char), do: rest
  defp tl_if_matches(stack, _char), do: stack

  defp maybe_drop_trailing_escape(out, true, true), do: String.trim_trailing(out, "\\")
  defp maybe_drop_trailing_escape(out, _in_string, _escaped), do: out

  defp trim_incomplete_json_tail(out) do
    out
    |> String.trim_trailing()
    |> String.replace(~r/,\s*$/, "")
    |> String.replace(~r/,\s*"[^"]*"\s*:\s*$/, "")
    |> String.replace(~r/"[^"]*"\s*:\s*$/, "")
    |> String.replace(~r/:\s*$/, "")
  end

  defp preview(text), do: String.slice(text, 0, 200)

  defp parser_error(parser, message, details) do
    {:error, Error.new(:output_parser_error, message, Map.put(details, :parser, parser))}
  end
end
