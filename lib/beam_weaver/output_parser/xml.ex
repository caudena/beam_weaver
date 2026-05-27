defmodule BeamWeaver.OutputParser.XML do
  @moduledoc false

  alias BeamWeaver.Core.Error

  @spec parse(String.t()) :: {:ok, map()} | {:error, Error.t()}
  def parse(text) do
    text
    |> String.trim()
    |> xml_candidate()
    |> parse_element()
    |> case do
      {:ok, node, rest} ->
        if String.trim(rest) == "" do
          {:ok, node}
        else
          parser_error(:xml_parser, "output contained trailing XML text", %{input: preview(rest)})
        end

      {:error, %Error{} = error} ->
        {:error, error}
    end
  rescue
    exception ->
      parser_error(:xml_parser, "output was not valid XML", %{
        reason: Exception.message(exception),
        input: preview(text)
      })
  catch
    _kind, reason ->
      parser_error(:xml_parser, "output was not valid XML", %{
        reason: inspect(reason),
        input: preview(text)
      })
  end

  def transform_chunks(%{children: []} = node), do: [node]

  def transform_chunks(%{children: children} = node) do
    Enum.map(children, fn child ->
      %{node | children: [child], text: Map.get(child, :text, "")}
    end)
  end

  defp xml_candidate(text) do
    text
    |> xml_fenced_candidate()
    |> strip_xml_declaration()
  end

  defp xml_fenced_candidate(text) do
    case Regex.run(~r/```(?:xml)?\s*(.*?)```/s, text) do
      [_match, candidate] -> String.trim(candidate)
      _other -> text
    end
  end

  defp strip_xml_declaration(text) do
    text
    |> String.trim()
    |> String.replace(~r/^<\?xml[^>]*\?>\s*/i, "")
  end

  defp parse_element("<" <> rest) do
    case Regex.run(~r/^([A-Za-z_][\w:\.-]*)([^>]*)>/, rest) do
      [match, name, attrs] ->
        after_start = String.slice(rest, byte_size(match)..-1//1)
        self_closing? = String.ends_with?(String.trim(attrs), "/")
        attrs = attrs |> String.trim_trailing("/") |> parse_attrs()

        if self_closing? do
          {:ok, xml_node(name, "", [], attrs), after_start}
        else
          case parse_children(name, after_start, [], []) do
            {:ok, text_parts, children, rest} ->
              text = text_parts |> Enum.reverse() |> Enum.join("") |> String.trim()
              {:ok, xml_node(name, text, Enum.reverse(children), attrs), rest}

            {:error, %Error{} = error} ->
              {:error, error}
          end
        end

      _other ->
        parser_error(:xml_parser, "output was not valid XML", %{input: preview("<" <> rest)})
    end
  end

  defp parse_element(text),
    do: parser_error(:xml_parser, "output was not valid XML", %{input: preview(text)})

  defp parse_children(name, text, text_parts, children) do
    closing = "</#{name}>"

    cond do
      String.starts_with?(text, closing) ->
        rest = String.slice(text, byte_size(closing)..-1//1)
        {:ok, text_parts, children, rest}

      String.starts_with?(text, "</") ->
        parser_error(:xml_parser, "XML closing tag did not match", %{expected: name})

      String.starts_with?(text, "<") ->
        with {:ok, child, rest} <- parse_element(text) do
          parse_children(name, rest, text_parts, [child | children])
        end

      text == "" ->
        parser_error(:xml_parser, "XML element was not closed", %{expected: name})

      true ->
        {part, rest} = take_until_tag(text)
        parse_children(name, rest, [part | text_parts], children)
    end
  end

  defp take_until_tag(text) do
    case :binary.match(text, "<") do
      {index, _length} -> {String.slice(text, 0, index), String.slice(text, index..-1//1)}
      :nomatch -> {text, ""}
    end
  end

  defp parse_attrs(attrs) do
    ~r/([A-Za-z_][\w:\.-]*)\s*=\s*"([^"]*)"/
    |> Regex.scan(attrs)
    |> Map.new(fn [_match, key, value] -> {key, value} end)
  end

  defp xml_node(name, text, children, attrs) when attrs == %{} do
    %{name: name, text: xml_text_value(text, children), children: children}
  end

  defp xml_node(name, text, children, attrs) do
    %{name: name, text: xml_text_value(text, children), children: children, attributes: attrs}
  end

  defp xml_text_value("", children) do
    children
    |> Enum.map_join("", &Map.get(&1, :text, ""))
    |> String.trim()
  end

  defp xml_text_value(text, _children), do: text

  defp preview(text), do: String.slice(text, 0, 200)

  defp parser_error(parser, message, details) do
    {:error, Error.new(:output_parser_error, message, Map.put(details, :parser, parser))}
  end
end
