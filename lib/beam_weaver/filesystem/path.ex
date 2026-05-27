defmodule BeamWeaver.Filesystem.Path do
  @moduledoc false

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

  def virtual_to_real(root, path) do
    with {:ok, path} <- clean_path(path) do
      relative = String.trim_leading(path, "/")
      root = secure_root(root)
      real = Elixir.Path.expand(Elixir.Path.join(root, relative))

      with true <- under_root?(real, root),
           {:ok, real} <- secure_candidate(real, root),
           true <- under_root?(real, root) do
        {:ok, real, path}
      else
        _error -> {:error, "invalid_path"}
      end
    end
  end

  def under_path?(path, "/"), do: String.starts_with?(path, "/")

  def under_path?(path, base) do
    base = String.trim_trailing(base, "/")
    path == base or String.starts_with?(path, base <> "/")
  end

  def relative(path, "/"), do: String.trim_leading(path, "/")
  def relative(path, base), do: String.trim_leading(String.replace_prefix(path, base, ""), "/")

  defp secure_root(root) do
    root = Elixir.Path.expand(root)

    case realpath_existing(root) do
      {:ok, real} -> real
      {:error, _reason} -> root
    end
  end

  defp secure_candidate(candidate, root) do
    case File.lstat(candidate) do
      {:ok, _stat} ->
        realpath_existing(candidate)

      {:error, _missing} ->
        ancestor = nearest_existing_parent(candidate, root)

        with {:ok, real_parent} <- realpath_existing(ancestor),
             true <- under_root?(real_parent, root) do
          {:ok, candidate}
        else
          _error -> {:error, :invalid_path}
        end
    end
  end

  defp nearest_existing_parent(path, root) do
    parent = Elixir.Path.dirname(path)

    cond do
      File.exists?(parent) -> parent
      parent == path -> root
      not under_root?(parent, root) -> root
      true -> nearest_existing_parent(parent, root)
    end
  end

  defp under_root?(path, root), do: path == root or String.starts_with?(path, root <> "/")

  defp realpath_existing(path, depth \\ 0)

  defp realpath_existing(_path, depth) when depth > 40, do: {:error, :eloop}

  defp realpath_existing(path, depth) do
    path = Elixir.Path.expand(path)

    case Elixir.Path.split(path) do
      ["/" | segments] -> resolve_segments("/", segments, depth)
      [segment | segments] -> resolve_segments(segment, segments, depth)
      [] -> {:ok, path}
    end
  end

  defp resolve_segments(current, [], _depth), do: {:ok, current}

  defp resolve_segments(current, [segment | rest], depth) do
    candidate = Elixir.Path.join(current, segment)

    case resolve_link_or_existing(candidate, depth) do
      {:ok, resolved} -> resolve_segments(resolved, rest, depth)
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_link_or_existing(candidate, depth) do
    case :file.read_link(String.to_charlist(candidate)) do
      {:ok, target} ->
        target = List.to_string(target)

        target =
          if Elixir.Path.type(target) == :absolute,
            do: target,
            else: Elixir.Path.expand(target, Elixir.Path.dirname(candidate))

        realpath_existing(target, depth + 1)

      {:error, :einval} ->
        if File.exists?(candidate), do: {:ok, candidate}, else: {:error, :enoent}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_leading_slash("/" <> _ = path), do: path
  defp ensure_leading_slash(path), do: "/" <> path
end
