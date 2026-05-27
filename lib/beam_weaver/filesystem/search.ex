defmodule BeamWeaver.Filesystem.Search do
  @moduledoc false

  alias BeamWeaver.Filesystem
  alias BeamWeaver.Filesystem.FileDataUtils
  alias BeamWeaver.Filesystem.FileInfo
  alias BeamWeaver.Filesystem.GrepMatch
  alias BeamWeaver.Filesystem.Path

  def immediate_entries(files, path) do
    prefix = if path == "/", do: "/", else: path <> "/"

    files
    |> Map.keys()
    |> Enum.filter(&String.starts_with?(&1, prefix))
    |> Enum.map(fn file_path ->
      rest = String.replace_prefix(file_path, prefix, "")
      [name | _tail] = String.split(rest, "/", parts: 2)
      child_path = if path == "/", do: "/" <> name, else: path <> "/" <> name
      {child_path, String.contains?(rest, "/")}
    end)
    |> Enum.uniq()
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {entry_path, dir?} ->
      %FileInfo{path: entry_path, is_dir: dir?, size: file_size(files[entry_path])}
    end)
  end

  def grep_files(files, pattern, opts \\ []) do
    base = Keyword.get(opts, :path, "/")
    glob = Keyword.get(opts, :glob)

    files
    |> Enum.filter(fn {path, _data} ->
      Path.under_path?(path, base) and glob_match?(path, glob, base)
    end)
    |> Enum.flat_map(fn {path, data} ->
      data = FileDataUtils.normalize_file_data(data)

      if data && data.encoding == "utf-8" do
        data.content
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.flat_map(fn {line, line_number} ->
          if String.contains?(line, pattern),
            do: [%GrepMatch{path: path, line: line_number, text: line}],
            else: []
        end)
      else
        []
      end
    end)
  end

  def grep_matches_from_files(files, pattern, opts \\ []),
    do: %Filesystem.GrepResult{matches: grep_files(files, pattern, opts)}

  def glob_files(files, pattern, opts \\ []) do
    base = Keyword.get(opts, :path, "/")

    files
    |> Map.keys()
    |> Enum.filter(fn path ->
      Path.under_path?(path, base) and wildcard_match?(Path.relative(path, base), pattern)
    end)
    |> Enum.sort()
    |> Enum.map(fn path -> %FileInfo{path: path, is_dir: false, size: file_size(files[path])} end)
  end

  def wildcard_match?(_value, nil), do: true
  def wildcard_match?(value, ""), do: value == ""

  def wildcard_match?(value, pattern) when is_binary(value) and is_binary(pattern) do
    regex =
      pattern
      |> Regex.escape()
      |> String.replace("\\*\\*", ".*")
      |> String.replace("\\*", "[^/]*")
      |> String.replace("\\?", "[^/]")
      |> then(&("^" <> &1 <> "$"))

    Regex.match?(Regex.compile!(regex), value)
  end

  def build_grep_results_dict(matches) do
    Enum.reduce(matches || [], %{}, fn
      %GrepMatch{path: path, line: line, text: text}, acc ->
        Map.update(acc, path, [{line, text}], &(&1 ++ [{line, text}]))

      %{path: path, line: line, text: text}, acc ->
        Map.update(acc, path, [{line, text}], &(&1 ++ [{line, text}]))

      %{"path" => path, "line" => line, "text" => text}, acc ->
        Map.update(acc, path, [{line, text}], &(&1 ++ [{line, text}]))
    end)
  end

  def format_grep_matches(matches, output_mode \\ :files_with_matches) do
    matches
    |> build_grep_results_dict()
    |> format_grep_results(output_mode)
  end

  def format_grep_results(results, output_mode \\ :files_with_matches)

  def format_grep_results(results, _output_mode) when map_size(results) == 0,
    do: "No matches found"

  def format_grep_results(results, output_mode)
      when output_mode in [:files_with_matches, "files_with_matches"] do
    results |> Map.keys() |> Enum.sort() |> Enum.join("\n")
  end

  def format_grep_results(results, output_mode) when output_mode in [:count, "count"] do
    results
    |> Enum.sort_by(fn {path, _matches} -> path end)
    |> Enum.map_join("\n", fn {path, matches} -> "#{path}: #{length(matches)}" end)
  end

  def format_grep_results(results, _output_mode) do
    results
    |> Enum.sort_by(fn {path, _matches} -> path end)
    |> Enum.flat_map(fn {path, matches} ->
      [path <> ":" | Enum.map(matches, fn {line, text} -> "  #{line}: #{text}" end)]
    end)
    |> Enum.join("\n")
  end

  defp glob_match?(_path, nil, _base), do: true
  defp glob_match?(path, glob, base), do: wildcard_match?(Path.relative(path, base), glob)

  defp file_size(nil), do: nil

  defp file_size(data),
    do: data |> FileDataUtils.normalize_file_data() |> then(&byte_size((&1 && &1.content) || ""))
end
