defmodule BeamWeaver.Filesystem.Path do
  @moduledoc false

  # The most symlinks one path may pass through, as on Linux.
  @max_links 40

  def sanitize_tool_call_id(tool_call_id) do
    tool_call_id
    |> to_string()
    |> String.replace([".", "/", "\\"], "_")
  end

  def to_posix_path(path), do: path |> to_string() |> String.replace("\\", "/")

  def validate_path(path, opts \\ []) do
    allowed_prefixes = Keyword.get(opts, :allowed_prefixes)
    original = to_string(path)
    path = to_posix_path(original)

    cond do
      original =~ ~r/^[A-Za-z]:/ ->
        raise ArgumentError,
              "Windows absolute paths are not supported: #{original}. Please use virtual paths starting with /"

      String.starts_with?(path, "~") or Enum.member?(Elixir.Path.split(path), "..") ->
        raise ArgumentError, "Path traversal not allowed: #{original}"

      true ->
        normalized =
          path
          |> Elixir.Path.expand("/")
          |> ensure_leading_slash()

        if allowed_prefixes &&
             not Enum.any?(allowed_prefixes, &String.starts_with?(normalized, &1)) do
          raise ArgumentError,
                "Path must start with one of #{inspect(allowed_prefixes)}: #{original}"
        end

        normalized
    end
  end

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
