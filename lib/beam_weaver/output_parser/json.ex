defmodule BeamWeaver.OutputParser.JSON do
  @moduledoc false

  alias BeamWeaver.Core.Error

  @max_partial_json_bytes 256 * 1024

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
    candidates = json_candidates(text)

    candidates
    |> Enum.find_value(&decode_partial_json_candidate/1) ||
      parser_error(:json_parser, "partial output was not valid JSON", %{
        reason: Exception.message(original_error),
        input: preview(text),
        max_partial_json_bytes: @max_partial_json_bytes
      })
  end

  defp decode_partial_json_candidate(candidate) when byte_size(candidate) > @max_partial_json_bytes,
    do: nil

  defp decode_partial_json_candidate(candidate) do
    candidate
    |> partial_json_candidates()
    |> Enum.find_value(fn candidate ->
      case BeamWeaver.JSON.decode(candidate) do
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

  defp python_dict?(text), do: Regex.match?(~r/^\s*[{[]/, text) and String.contains?(text, "'")

  defp python_dict_to_json(text) do
    text
    |> String.replace(~r/'([^']*)'/, "\"\\1\"")
    |> String.replace("None", "null")
    |> String.replace("True", "true")
    |> String.replace("False", "false")
  end

  defp partial_json_candidates(candidate) do
    [candidate, complete_json_prefix(candidate), repair_json(candidate)]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp complete_json_prefix(candidate) do
    candidate
    |> String.trim_leading()
    |> complete_json_prefix(0, [], false, false, false, nil)
  end

  defp complete_json_prefix(candidate, index, _stack, _in_string, _escaped, _started, _root)
       when index >= byte_size(candidate),
       do: nil

  defp complete_json_prefix(candidate, index, stack, in_string, escaped, started, root) do
    byte = :binary.at(candidate, index)
    next_index = index + 1

    cond do
      not started and whitespace?(byte) ->
        complete_json_prefix(candidate, next_index, stack, false, false, false, nil)

      not started and byte == ?{ ->
        complete_json_prefix(candidate, next_index, [?} | stack], false, false, true, :container)

      not started and byte == ?[ ->
        complete_json_prefix(candidate, next_index, [?] | stack], false, false, true, :container)

      not started and byte == ?" ->
        complete_json_prefix(candidate, next_index, stack, true, false, true, :string)

      not started ->
        nil

      in_string and escaped ->
        complete_json_prefix(candidate, next_index, stack, true, false, true, root)

      in_string and byte == ?\\ ->
        complete_json_prefix(candidate, next_index, stack, true, true, true, root)

      in_string and byte == ?" and root == :string ->
        binary_part(candidate, 0, next_index)

      in_string and byte == ?" ->
        complete_json_prefix(candidate, next_index, stack, false, false, true, root)

      in_string ->
        complete_json_prefix(candidate, next_index, stack, true, false, true, root)

      byte == ?" ->
        complete_json_prefix(candidate, next_index, stack, true, false, true, root)

      byte == ?{ ->
        complete_json_prefix(candidate, next_index, [?} | stack], false, false, true, root)

      byte == ?[ ->
        complete_json_prefix(candidate, next_index, [?] | stack], false, false, true, root)

      byte in [?}, ?]] ->
        case pop_matching(stack, byte) do
          {:ok, []} -> binary_part(candidate, 0, next_index)
          {:ok, rest} -> complete_json_prefix(candidate, next_index, rest, false, false, true, root)
          :error -> nil
        end

      true ->
        complete_json_prefix(candidate, next_index, stack, false, false, true, root)
    end
  end

  defp repair_json(candidate) do
    {out, stack, in_string, escaped} =
      candidate
      |> String.graphemes()
      |> Enum.reduce({[], [], false, false}, fn char, {out, stack, in_string, escaped} ->
        cond do
          in_string and escaped ->
            {[char | out], stack, true, false}

          in_string and char == "\\" ->
            {[char | out], stack, true, true}

          in_string and char == "\"" ->
            {[char | out], stack, false, false}

          in_string and char == "\n" ->
            {["\\n" | out], stack, true, false}

          in_string and char == "\r" ->
            {["\\r" | out], stack, true, false}

          in_string and char == "\t" ->
            {["\\t" | out], stack, true, false}

          in_string ->
            {[char | out], stack, true, false}

          char == "\"" ->
            {[char | out], stack, true, false}

          char == "{" ->
            {[char | out], ["}" | stack], false, false}

          char == "[" ->
            {[char | out], ["]" | stack], false, false}

          char in ["}", "]"] ->
            {[char | out], tl_if_matches(stack, char), false, false}

          true ->
            {[char | out], stack, false, false}
        end
      end)

    {out, close_string?} =
      out
      |> Enum.reverse()
      |> IO.iodata_to_binary()
      |> maybe_drop_trailing_escape(in_string, escaped)
      |> trim_incomplete_json_tail(stack, in_string)

    out = if close_string?, do: out <> "\"", else: out
    out <> Enum.join(stack)
  end

  defp whitespace?(byte), do: byte in [?\s, ?\n, ?\r, ?\t]

  defp pop_matching([char | rest], char), do: {:ok, rest}
  defp pop_matching(_stack, _char), do: :error

  defp tl_if_matches([char | rest], char), do: rest
  defp tl_if_matches(stack, _char), do: stack

  defp maybe_drop_trailing_escape(out, true, true), do: String.trim_trailing(out, "\\")
  defp maybe_drop_trailing_escape(out, _in_string, _escaped), do: out

  defp trim_incomplete_json_tail(out, stack, in_string) do
    original = String.trim_trailing(out)
    trimmed = if object_context?(stack), do: trim_incomplete_object_tail(original), else: original

    out =
      trimmed
      |> String.replace(~r/,\s*$/, "")
      |> String.replace(~r/,\s*"[^"]*"\s*:\s*$/, "")
      |> String.replace(~r/"[^"]*"\s*:\s*$/, "")
      |> String.replace(~r/:\s*$/, "")

    {out, in_string and trimmed == original}
  end

  defp object_context?(["}" | _rest]), do: true
  defp object_context?(_stack), do: false

  defp trim_incomplete_object_tail(out) do
    out
    |> String.replace(~r/([{,])\s*"[^"]*"\s*$/, "\\1")
    |> String.replace(~r/([{,])\s*"[^"]*$/, "\\1")
  end

  defp preview(text), do: String.slice(text, 0, 200)

  defp parser_error(parser, message, details) do
    {:error, Error.new(:output_parser_error, message, Map.put(details, :parser, parser))}
  end
end
