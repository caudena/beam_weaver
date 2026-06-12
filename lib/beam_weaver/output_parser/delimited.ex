defmodule BeamWeaver.OutputParser.Delimited do
  @moduledoc false

  @spec list(String.t(), String.t() | nil) :: [String.t()]
  def list(text, separator)

  def list(text, separator) when is_binary(separator) do
    text |> String.split(separator, trim: true) |> Enum.map(&String.trim/1)
  end

  def list(text, _separator) do
    items =
      text
      |> String.split(~r/\r?\n|,/, trim: true)
      |> Enum.map(&String.trim/1)

    items =
      if Enum.any?(items, &list_marker?/1) do
        Enum.filter(items, &list_marker?/1)
      else
        items
      end

    items
    |> Enum.map(&String.replace(&1, ~r/^[-*]\s+|^\d+[\.\)]\s+/, ""))
    |> Enum.reject(&(&1 == ""))
  end

  def markdown_list(text) do
    text
    |> String.split(~r/\r?\n/, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&Regex.match?(~r/^([-*+]|\d+[\.\)])\s+/, &1))
    |> Enum.map(&String.replace(&1, ~r/^([-*+]|\d+[\.\)])\s+/, ""))
  end

  def numbered_list(text) do
    text
    |> String.split(~r/\r?\n/, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&Regex.match?(~r/^\d+\.\s+/, &1))
    |> Enum.map(&String.replace(&1, ~r/^\d+\.\s+/, ""))
  end

  def comma_separated_list(text, separator \\ ",") do
    text
    |> csv(separator)
    |> List.flatten()
  end

  def csv(text, separator \\ ",") do
    text
    |> String.split(~r/\r?\n/, trim: true)
    |> Enum.map(fn line -> split_csv_line(line, separator) end)
  end

  defp split_csv_line(line, separator) do
    separator = Regex.escape(separator)

    ~r/#{separator}(?=(?:[^"]*"[^"]*")*[^"]*$)/
    |> Regex.split(line)
    |> Enum.map(&String.trim/1)
    |> Enum.map(&String.trim(&1, "\""))
  end

  defp list_marker?(line), do: Regex.match?(~r/^([-*]|\d+[\.\)])\s+/, line)
end
