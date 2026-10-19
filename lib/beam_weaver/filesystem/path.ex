defmodule BeamWeaver.Filesystem.Path do
  @moduledoc false

  # The most symlinks one path may pass through, as on Linux.
  @max_links 40

  def clean_path(path) when is_binary(path) do
    cond do
      not String.starts_with?(path, "/") ->
        {:error, "invalid_path"}

      String.contains?(path, ["\0", "~"]) ->
        {:error, "invalid_path"}

      Enum.member?(Elixir.Path.split(path), "..") ->
        {:error, "invalid_path"}

      true ->
        path =
          path
          |> Elixir.Path.expand("/")
          |> ensure_leading_slash()

        {:ok, path}
    end
  end

  def clean_path(_path), do: {:error, "invalid_path"}

  # A glob pattern must stay under the directory it searches: no `..`
  # segment, not even one spelled with `\` escapes such as `.\.`, which the
  # matcher reads as `..`, and, as in a path, no `~`.
  def clean_pattern(pattern) when is_binary(pattern) do
    segments = pattern |> String.replace("\\", "") |> String.split("/")

    if String.contains?(pattern, ["\0", "~"]) or ".." in segments,
      do: {:error, "invalid_pattern"},
      else: {:ok, pattern}
  end

  def clean_pattern(_pattern), do: {:error, "invalid_pattern"}

  # The glob rule of `glob` and of grep's `glob:` filter, as a pattern for
  # the path below the directory searched: a pattern without `/` matches a
  # name at any depth, so `*.py` is `**/*.py`; one with `/` matches the path
  # from that directory, and a leading `/` only anchors it there, so `/*.py`
  # matches its top-level files.
  def search_pattern("/" <> pattern), do: String.trim_leading(pattern, "/")
  def search_pattern(""), do: ""

  def search_pattern(pattern) when is_binary(pattern),
    do: if(String.contains?(pattern, "/"), do: pattern, else: "**/" <> pattern)

  def search_pattern(pattern), do: pattern

  # Grep's `glob:` filter as a `search_pattern/1`, or `nil` to search every
  # file when there is none.
  def grep_pattern(glob) when glob in [nil, ""], do: nil
  def grep_pattern(glob), do: search_pattern(glob)

  # A `search_pattern/1` as a regular expression for the path below the
  # directory searched, which POSIX extended syntax, as `find -regex` reads
  # it, and Elixir's `Regex` read alike: `**/` is any number of folders, `**`
  # anything, `*` and `?` stay within one name, `[...]` is a class, one that
  # starts with `!` or `^` excludes its members, `{a,b}` is either, and `\`
  # makes the next character literal. An unclosed `[` or `{` is an invalid
  # pattern.
  def glob_regex(pattern) when is_binary(pattern), do: glob_regex(pattern, 0, [])

  defp glob_regex("", 0, acc), do: {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary()}
  defp glob_regex("", _depth, _acc), do: {:error, "invalid_pattern"}
  defp glob_regex("**/" <> rest, depth, acc), do: glob_regex(rest, depth, ["(.*/)?" | acc])
  defp glob_regex("**" <> rest, depth, acc), do: glob_regex(rest, depth, [".*" | acc])
  defp glob_regex("*" <> rest, depth, acc), do: glob_regex(rest, depth, ["[^/]*" | acc])
  defp glob_regex("?" <> rest, depth, acc), do: glob_regex(rest, depth, ["[^/]" | acc])
  defp glob_regex("{" <> rest, depth, acc), do: glob_regex(rest, depth + 1, ["(" | acc])
  defp glob_regex("}" <> rest, depth, acc) when depth > 0, do: glob_regex(rest, depth - 1, [")" | acc])
  defp glob_regex("," <> rest, depth, acc) when depth > 0, do: glob_regex(rest, depth, ["|" | acc])

  defp glob_regex(<<"\\", char::utf8, rest::binary>>, depth, acc),
    do: glob_regex(rest, depth, [regex_literal(<<char::utf8>>) | acc])

  defp glob_regex("[" <> rest, depth, acc) do
    case glob_class(rest) do
      {:class, "", members, rest} -> glob_regex(rest, depth, ["[" <> class_members(members) <> "]" | acc])
      {:class, _excluded, members, rest} -> glob_regex(rest, depth, ["[^/" <> class_members(members) <> "]" | acc])
      :literal -> glob_regex(rest, depth, ["\\[" | acc])
      :unclosed -> {:error, "invalid_pattern"}
    end
  end

  defp glob_regex(<<char::utf8, rest::binary>>, depth, acc),
    do: glob_regex(rest, depth, [regex_literal(<<char::utf8>>) | acc])

  # The class that `rest`, what follows a `[`, starts with. A `]` right after
  # `[` or `[!` is a member, not the end, so `[]` alone is the two literal
  # characters.
  defp glob_class(rest) do
    case Regex.run(~r/\A([!^]?)(\]?[^\]]*)\](.*)\z/s, rest) do
      [_all, _excluded, "", _rest] -> :literal
      [_all, excluded, members, rest] -> {:class, excluded, members, rest}
      nil -> :unclosed
    end
  end

  # A `\` among a class's members is literal in POSIX syntax and an escape in
  # Elixir's; doubled, it is a literal backslash in both.
  defp class_members(members), do: String.replace(members, "\\", "\\\\")

  @regex_specials [".", "^", "$", "+", "*", "?", "(", ")", "|", "{", "}", "[", "]", "\\"]

  defp regex_literal(char) when char in @regex_specials, do: "\\" <> char
  defp regex_literal(char), do: char

  # A matcher for `glob_regex/1`'s pattern, or its error.
  def glob_matcher(""), do: {:ok, &(&1 == "")}

  def glob_matcher(pattern) do
    with {:ok, source} <- glob_regex(pattern) do
      regex = Regex.compile!("\\A" <> source <> "\\z", "u")
      {:ok, &Regex.match?(regex, &1)}
    end
  end

  # `pattern` for a directory walk with `Path.wildcard/2`, which has no
  # excluding classes and reads class members its own way: each class
  # becomes `?`, so the walk finds every file the pattern can match, and
  # `glob_matcher/1` picks the ones it does.
  def walk_pattern(pattern), do: walk_pattern(pattern, 0, [])

  defp walk_pattern("", _depth, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp walk_pattern(<<"\\", char::utf8, rest::binary>>, depth, acc),
    do: walk_pattern(rest, depth, [<<"\\", char::utf8>> | acc])

  defp walk_pattern("{" <> rest, depth, acc), do: walk_pattern(rest, depth + 1, ["{" | acc])
  defp walk_pattern("}" <> rest, depth, acc) when depth > 0, do: walk_pattern(rest, depth - 1, ["}" | acc])
  defp walk_pattern("}" <> rest, depth, acc), do: walk_pattern(rest, depth, ["\\}" | acc])
  defp walk_pattern("," <> rest, 0, acc), do: walk_pattern(rest, 0, ["\\," | acc])

  defp walk_pattern("[" <> rest, depth, acc) do
    case glob_class(rest) do
      {:class, _excluded, _members, rest} -> walk_pattern(rest, depth, ["?" | acc])
      _literal -> walk_pattern(rest, depth, ["\\[" | acc])
    end
  end

  defp walk_pattern(<<char::utf8, rest::binary>>, depth, acc), do: walk_pattern(rest, depth, [<<char::utf8>> | acc])

  def virtual_to_real(root, path), do: root |> real_root() |> resolve_virtual(path)

  # `root` with its symlinks resolved, to resolve many paths under it with
  # `resolve_virtual/2` without resolving the root again for each.
  def real_root(root) do
    root = Elixir.Path.expand(root)

    case realpath_existing(root) do
      {:ok, real} -> real
      {:error, _reason} -> root
    end
  end

  def resolve_virtual(real_root, path) do
    with {:ok, path} <- clean_path(path),
         {:ok, real} <- resolve_under_root(real_root, path |> Elixir.Path.split() |> tl(), real_root) do
      {:ok, real, path}
    else
      _error -> {:error, "invalid_path"}
    end
  end

  # The virtual path of the file `path` reaches under `real_root`: the real
  # path `resolve_virtual/2` resolves it to, which has every symlink on the
  # way followed, relative to the root.
  def canonical_path(real_root, path) do
    with {:ok, real, _virtual} <- resolve_virtual(real_root, path) do
      {:ok, real_to_virtual(real_root, real)}
    end
  end

  defp real_to_virtual(root, root), do: "/"
  defp real_to_virtual("/", real), do: real
  defp real_to_virtual(root, real), do: String.replace_prefix(real, root, "")

  def under_path?(path, "/"), do: String.starts_with?(path, "/")

  def under_path?(path, base) do
    base = String.trim_trailing(base, "/")
    path == base or String.starts_with?(path, base <> "/")
  end

  def relative(path, "/"), do: String.trim_leading(path, "/")
  def relative(path, base), do: String.trim_leading(String.replace_prefix(path, base, ""), "/")

  def join_virtual(base, ""), do: base
  def join_virtual(base, relative), do: String.trim_trailing(base, "/") <> "/" <> String.trim_leading(relative, "/")

  # Follows `segments` from `current`, a real directory under the real
  # `root`, resolving each symlink on the way. A symlink that points outside
  # the root fails the path, even when a later segment leads back in. Once a
  # segment doesn't exist, nothing below it does either, so the rest are
  # joined as they are: the path where a new file would go.
  defp resolve_under_root(_root, [], current), do: {:ok, current}

  defp resolve_under_root(root, [segment | rest], current) do
    candidate = Elixir.Path.join(current, segment)

    case :file.read_link(String.to_charlist(candidate)) do
      {:ok, target} ->
        with {:ok, resolved} <- follow_link(current, target, 0),
             true <- under_root?(resolved, root) do
          resolve_under_root(root, rest, resolved)
        else
          _outside_or_dangling -> {:error, :invalid_path}
        end

      {:error, :einval} ->
        resolve_under_root(root, rest, candidate)

      {:error, _missing} ->
        {:ok, Elixir.Path.join([candidate | rest])}
    end
  end

  defp under_root?(path, root), do: path == root or String.starts_with?(path, root <> "/")

  # The real path of `path`, an absolute path to something that exists.
  defp realpath_existing(path) do
    case Elixir.Path.split(path) do
      ["/" | segments] -> walk("/", segments, 0)
      _relative -> {:error, :einval}
    end
  end

  # Follows `segments` from `current`, a real directory, to something that
  # exists, following symlinks the way the OS does: a `..` climbs from where
  # the path has led so far, so after a symlink it climbs from the link's
  # target, not from the link. Reading `..` as text instead would check one
  # file and open another.
  defp walk(current, [], _links), do: {:ok, current}
  defp walk(current, ["." | rest], links), do: walk(current, rest, links)
  defp walk(current, [".." | rest], links), do: walk(Elixir.Path.dirname(current), rest, links)

  defp walk(current, [segment | rest], links) do
    candidate = Elixir.Path.join(current, segment)

    case :file.read_link(String.to_charlist(candidate)) do
      {:ok, target} -> follow_link(current, target, links, rest)
      {:error, :einval} -> if File.exists?(candidate), do: walk(candidate, rest, links), else: {:error, :enoent}
      {:error, reason} -> {:error, reason}
    end
  end

  # Follows the symlink `target`, read from a link in the real directory
  # `dir`, and then `rest`. An absolute target starts again from `/`.
  defp follow_link(dir, target, links, rest \\ [])

  defp follow_link(_dir, _target, links, _rest) when links >= @max_links, do: {:error, :eloop}

  defp follow_link(dir, target, links, rest) do
    case target |> IO.chardata_to_string() |> Elixir.Path.split() do
      ["/" | segments] -> walk("/", segments ++ rest, links + 1)
      segments -> walk(dir, segments ++ rest, links + 1)
    end
  end

  defp ensure_leading_slash("/" <> _ = path), do: path
  defp ensure_leading_slash(path), do: "/" <> path
end
