defmodule BeamWeaver.Filesystem.Permission do
  @moduledoc """
  Ordered allow/deny rule for agent filesystem tools.

  Rules are evaluated in list order. The first matching rule decides access;
  if no rule matches, access is allowed.

  A path pattern is absolute. `*` and `?` match within one folder, `**`
  matches any depth, `{a,b}` matches either name, and a pattern that ends in
  `/**` covers the folder itself and everything in it, so `/**/secrets/**`
  covers every `secrets` folder.

  Rules see a path as the backends read it: `/./secrets//key.txt` is
  `/secrets/key.txt`. When rules cover the operation, a path that can't be
  read that way, such as a relative path or one with `..`, `~` or `\\`, is
  denied. Deny rules also ignore case and Unicode normalization, because a
  disk that ignores them, such as macOS's, opens `/secrets/key.txt` for
  `/SECRETS/key.txt`; allow rules match exactly.

  `allowed?/3` checks a path on its own. The file tools check with
  `allowed?/5`, which also checks the file the path leads to on a backend, so
  a symlink to a denied file is denied too.
  """

  alias BeamWeaver.Filesystem
  alias BeamWeaver.Filesystem.Path, as: FsPath
  alias BeamWeaver.Filesystem.Search

  defstruct operations: [:read, :write], paths: ["/**"], mode: :allow

  @type operation :: :read | :write | String.t()
  @type mode :: :allow | :deny | String.t()
  @type t :: %__MODULE__{operations: [operation()], paths: [String.t()], mode: mode()}

  def new(opts \\ []) do
    operations =
      opts
      |> Keyword.get(:operations, [:read, :write])
      |> List.wrap()
      |> Enum.map(&normalize_operation/1)

    paths =
      opts
      |> Keyword.get(:paths, ["/**"])
      |> List.wrap()
      |> Enum.map(&validate_path!/1)

    mode = opts |> Keyword.get(:mode, :allow) |> normalize_mode()

    %__MODULE__{
      operations: operations,
      paths: paths,
      mode: mode
    }
  end

  @spec allowed?([t() | map() | keyword()], operation(), String.t()) :: boolean()
  def allowed?(permissions, operation, path) do
    decision(permissions, operation, path) == :allow
  end

  @doc """
  Whether the rules allow `operation` on `path` of `backend`.

  The rules must allow both `path` and the path of the file `backend` reaches
  through it, from `BeamWeaver.Filesystem.canonical_paths/3`. So with a symlink
  `/notes/key.txt` to `/secrets/key.txt` in a `BeamWeaver.Filesystem.Local`
  directory, a deny rule for `/secrets/**` denies `/notes/key.txt` too, and an
  allow rule for `/notes/**` alone doesn't allow it. When rules cover the
  operation and the backend can't resolve the path, such as a broken link,
  the path is denied. The file tools check paths this way, right before each
  call; a link that another process changes after the check can still lead
  the call elsewhere. `opts` are the backend options, such as `:state` and
  `:store`.
  """
  @spec allowed?([t() | map() | keyword()], operation(), String.t(), Filesystem.t(), keyword()) :: boolean()
  def allowed?(permissions, operation, path, backend, opts \\ []) do
    filter_paths(permissions, operation, [path], backend, opts) != []
  end

  @spec decision([t() | map() | keyword()], operation(), String.t()) :: :allow | :deny
  def decision(permissions, operation, path) do
    permissions
    |> rules(operation)
    |> decide(match_path(path))
  end

  @spec filter_paths([t() | map() | keyword()], operation(), [String.t()]) :: [String.t()]
  def filter_paths(permissions, operation, paths) when is_list(paths) do
    Enum.filter(paths, &allowed?(permissions, operation, &1))
  end

  @doc """
  The paths in `paths` that the rules allow `operation` on, checked like
  `allowed?/5` with one call to `backend` for all of them.
  """
  @spec filter_paths([t() | map() | keyword()], operation(), [String.t()], Filesystem.t(), keyword()) ::
          [String.t()]
  def filter_paths(permissions, operation, paths, backend, opts \\ []) when is_list(paths) do
    case rules(permissions, operation) do
      [] ->
        paths

      rules ->
        named = paths |> Enum.uniq() |> Enum.filter(&(decide(rules, match_path(&1)) == :allow))
        allowed = allowed_files(rules, named, backend, opts)
        Enum.filter(paths, &MapSet.member?(allowed, &1))
    end
  end

  # The paths in `paths` whose file the rules allow too. A backend that
  # answers with fewer or more paths than it was asked about allows none.
  defp allowed_files(_rules, [], _backend, _opts), do: MapSet.new()

  defp allowed_files(rules, paths, backend, opts) do
    results = Filesystem.canonical_paths(backend, paths, opts)

    if is_list(results) and length(results) == length(paths) do
      for {path, {:ok, canonical}} <- Enum.zip(paths, results),
          decide(rules, match_path(canonical)) == :allow,
          into: MapSet.new(),
          do: path
    else
      MapSet.new()
    end
  end

  defp rules(permissions, operation) do
    operation = normalize_operation(operation)

    permissions
    |> List.wrap()
    |> Enum.map(&normalize/1)
    |> Enum.filter(&(operation in &1.operations))
  end

  def normalize(%__MODULE__{} = permission), do: permission

  def normalize(permission) when is_map(permission) do
    new(
      operations: Map.get(permission, :operations, Map.get(permission, "operations", [:read, :write])),
      paths: Map.get(permission, :paths, Map.get(permission, "paths", ["/**"])),
      mode: Map.get(permission, :mode, Map.get(permission, "mode", :allow))
    )
  end

  def normalize(permission) when is_list(permission), do: new(permission)

  defp decide([], _path), do: :allow
  defp decide(_permissions, :error), do: :deny

  defp decide(permissions, {:ok, path}) do
    Enum.find_value(permissions, :allow, fn permission ->
      if Enum.any?(permission.paths, &path_match?(path, &1, permission.mode)), do: permission.mode
    end)
  end

  # The path as the backends read it, or `:error` when a backend might read
  # it as another path than the rules would see.
  defp match_path(path) when is_binary(path) do
    with false <- String.contains?(path, "\\"),
         {:ok, path} <- FsPath.clean_path(path) do
      {:ok, path}
    else
      _unclear -> :error
    end
  end

  defp match_path(_path), do: :error

  defp path_match?(path, pattern, mode) do
    pattern = pattern |> to_string() |> String.replace("\\", "/") |> Path.expand("/")
    {path, pattern} = if mode == :deny, do: {fold(path), fold(pattern)}, else: {path, pattern}

    pattern
    |> expand_braces()
    |> Enum.any?(&glob_match?(path, &1))
  end

  # A disk that ignores case and Unicode normalization, such as macOS's,
  # opens the same file for every spelling, so deny rules match them all.
  defp fold(string), do: string |> String.normalize(:nfc) |> String.downcase()

  defp glob_match?(path, pattern) do
    folder = String.trim_trailing(pattern, "/**")

    cond do
      folder == pattern ->
        Search.wildcard_match?(path, pattern)

      String.contains?(folder, ["*", "?"]) ->
        Search.wildcard_match?(path, folder) or Search.wildcard_match?(path, pattern)

      true ->
        folder == "" or path == folder or String.starts_with?(path, folder <> "/")
    end
  end

  defp normalize_operation(operation) when operation in [:read, "read"], do: :read
  defp normalize_operation(operation) when operation in [:write, "write"], do: :write

  defp normalize_operation(operation) do
    raise ArgumentError, "permission operation must be read or write, got: #{inspect(operation)}"
  end

  defp normalize_mode(mode) when mode in [:allow, "allow"], do: :allow
  defp normalize_mode(mode) when mode in [:deny, "deny"], do: :deny

  defp normalize_mode(mode) do
    raise ArgumentError, "permission mode must be allow or deny, got: #{inspect(mode)}"
  end

  defp validate_path!(path) when is_binary(path) do
    normalized = String.replace(path, "\\", "/")

    cond do
      not String.starts_with?(path, "/") ->
        raise ArgumentError, "permission path must start with '/'"

      String.contains?(normalized, "~") ->
        raise ArgumentError, "permission path must not contain '~'"

      ".." in Path.split(normalized) ->
        raise ArgumentError, "permission path must not contain '..'"

      true ->
        path
    end
  end

  defp validate_path!(path) do
    raise ArgumentError, "permission path must be a string, got: #{inspect(path)}"
  end

  defp expand_braces(pattern) do
    case Regex.run(~r/\{([^{}]+)\}/, pattern, return: :index) do
      [{start, len}, {inner_start, inner_len}] ->
        prefix = binary_part(pattern, 0, start)
        suffix = binary_part(pattern, start + len, byte_size(pattern) - start - len)
        inner = binary_part(pattern, inner_start, inner_len)

        inner
        |> String.split(",")
        |> Enum.flat_map(&((prefix <> &1 <> suffix) |> expand_braces()))

      nil ->
        [pattern]
    end
  end
end
