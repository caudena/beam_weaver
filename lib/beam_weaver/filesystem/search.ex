defmodule BeamWeaver.Filesystem.Search do
  @moduledoc false

  alias BeamWeaver.Filesystem.FileDataUtils
  alias BeamWeaver.Filesystem.FileInfo
  alias BeamWeaver.Filesystem.GrepMatch
  alias BeamWeaver.Filesystem.Path

  def immediate_entries(files, path) do
    prefix = if path == "/", do: "/", else: path <> "/"

    for file_path <- Map.keys(files), String.starts_with?(file_path, prefix), uniq: true do
      rest = String.replace_prefix(file_path, prefix, "")
      [name | _tail] = String.split(rest, "/", parts: 2)
      {prefix <> name, String.contains?(rest, "/")}
    end
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {entry_path, dir?} ->
      %FileInfo{path: entry_path, is_dir: dir?, size: file_size(files[entry_path])}
    end)
  end

  def grep_files(files, pattern, opts) do
    base = Keyword.get(opts, :path, "/")

    with {:ok, glob_match?} <- search_matcher(opts |> Keyword.get(:glob) |> Path.grep_pattern()) do
      matches =
        for {path, data} <- files,
            Path.under_path?(path, base) and (path == base or glob_match?.(Path.relative(path, base))),
            %{encoding: "utf-8", content: content} <- [FileDataUtils.normalize_file_data(data)],
            {line, line_number} <- content |> String.split("\n") |> Enum.with_index(1),
            String.contains?(line, pattern),
            do: %GrepMatch{path: path, line: line_number, text: line}

      {:ok, matches}
    end
  end

  def glob_files(files, pattern, opts) do
    base = Keyword.get(opts, :path, "/")

    with {:ok, pattern_match?} <- pattern |> Path.search_pattern() |> search_matcher() do
      {:ok,
       files
       |> Map.keys()
       |> Enum.filter(&(Path.under_path?(&1, base) and pattern_match?.(Path.relative(&1, base))))
       |> Enum.sort()
       |> Enum.map(fn path -> %FileInfo{path: path, is_dir: false, size: file_size(files[path])} end)}
    end
  end

  defp search_matcher(nil), do: {:ok, fn _relative -> true end}
  defp search_matcher(pattern), do: Path.glob_matcher(pattern)

  # Permission rules keep their own wildcards: `*`, `?` and `**`, without
  # the classes and alternatives of search patterns.
  def wildcard_match?(value, pattern) when is_binary(value), do: matcher(pattern).(value)

  defp matcher(nil), do: fn _value -> true end
  defp matcher(""), do: &(&1 == "")

  defp matcher(pattern) when is_binary(pattern) do
    regex = wildcard_regex(pattern)
    &Regex.match?(regex, &1)
  end

  # `**/` matches zero or more directories, so `**/*.md` also matches a
  # top-level `a.md`; `**` elsewhere matches anything, `*` and `?` stay within
  # one path segment.
  defp wildcard_regex(pattern) do
    pattern
    |> Regex.escape()
    |> String.replace("\\*\\*/", "(?:.*/)?")
    |> String.replace("\\*\\*", ".*")
    |> String.replace("\\*", "[^/]*")
    |> String.replace("\\?", "[^/]")
    |> then(&Regex.compile!("^" <> &1 <> "$"))
  end

  defp file_size(nil), do: nil

  defp file_size(data),
    do: data |> FileDataUtils.normalize_file_data() |> then(&byte_size((&1 && &1.content) || ""))
end
