defmodule BeamWeaver.Filesystem.Composite do
  @moduledoc """
  Routes virtual path prefixes to different filesystem backends, with a default
  backend for other paths.

  A routed backend sees paths without the route's prefix (`/policies/refunds.md`
  reaches the `/policies/` backend as `/refunds.md`) and gets the prefix as the
  `:route_prefix` option, so a backend that stores files in the shared graph
  state, such as `BeamWeaver.Filesystem.State`, keeps them under their full
  path. Paths under a route belong to it. A folder of the default backend
  holds the routes below it: listing it shows the next folder on the way to
  each, a search of it searches them too, and it exists when only a route is
  below it. When a backend fails such a listing or search, the result is
  that backend's error.
  """

  use BeamWeaver.Filesystem
  use BeamWeaver.Filesystem.Executable

  alias BeamWeaver.Filesystem
  alias BeamWeaver.Filesystem.Executable
  alias BeamWeaver.Filesystem.Path, as: FsPath
  alias BeamWeaver.Filesystem.State

  defstruct default: State.new(), routes: %{}, artifacts_root: "/"

  def new(opts \\ []) do
    routes =
      opts
      |> Keyword.get(:routes, %{})
      |> Map.new(fn {prefix, backend} -> {normalize_prefix(prefix), backend} end)

    %__MODULE__{
      default: Keyword.get(opts, :default, State.new()),
      routes: routes,
      artifacts_root: normalize_artifacts_root(Keyword.get(opts, :artifacts_root, "/"))
    }
  end

  def executable?(%__MODULE__{} = backend), do: Executable.executable?(backend.default)

  @impl true
  def ls(%__MODULE__{} = backend, path, opts) do
    case route(backend, path) do
      {nil, _default, path} ->
        ls_with_routes(backend, path, opts)

      {prefix, inner, stripped} ->
        inner
        |> Filesystem.ls(stripped, route_opts(opts, prefix))
        |> prefix_entries(:entries, prefix)
    end
  end

  defp ls_with_routes(backend, path, opts) do
    folders = route_folders(backend, path)

    case Filesystem.ls(backend.default, path, opts) do
      %Filesystem.LsResult{error: nil, entries: entries} ->
        entries = backend |> reject_routed(entries || []) |> Kernel.++(folders) |> Enum.uniq_by(& &1.path)
        %Filesystem.LsResult{entries: Enum.sort_by(entries, & &1.path)}

      %Filesystem.LsResult{error: "file_not_found"} when folders != [] ->
        %Filesystem.LsResult{entries: folders}

      error ->
        error
    end
  end

  # The folders in `path` on the way to the routes below it.
  defp route_folders(backend, path) do
    base = folder(path)

    for prefix <- Map.keys(backend.routes), String.starts_with?(prefix, base), uniq: true do
      [next | _rest] = prefix |> String.replace_prefix(base, "") |> String.split("/")
      %Filesystem.FileInfo{path: base <> next, is_dir: true}
    end
    |> Enum.sort_by(& &1.path)
  end

  defp folder("/"), do: "/"
  defp folder(path), do: String.trim_trailing(path, "/") <> "/"

  @impl true
  def read(%__MODULE__{} = backend, path, opts) do
    {prefix, inner, stripped} = route(backend, path)
    Filesystem.read(inner, stripped, route_opts(opts, prefix))
  end

  @impl true
  def glob(%__MODULE__{} = backend, pattern, opts),
    do: search(backend, pattern, opts, %Filesystem.GlobResult{}, & &1.path, &Filesystem.glob/3)

  @impl true
  def grep(%__MODULE__{} = backend, pattern, opts) do
    grep = fn inner, glob, opts -> Filesystem.grep(inner, pattern, Keyword.put(opts, :glob, glob)) end
    search(backend, Keyword.get(opts, :glob), opts, %Filesystem.GrepResult{}, &{&1.path, &1.line}, grep)
  end

  @impl true
  def write(%__MODULE__{} = backend, path, content, opts) do
    {prefix, inner, stripped} = route(backend, path)

    inner
    |> Filesystem.write(stripped, content, route_opts(opts, prefix))
    |> prefix_result(prefix)
  end

  @impl true
  def edit(%__MODULE__{} = backend, path, old, new, opts) do
    {prefix, inner, stripped} = route(backend, path)

    inner
    |> Filesystem.edit(stripped, old, new, route_opts(opts, prefix))
    |> prefix_result(prefix)
  end

  @impl true
  def upload_files(%__MODULE__{} = backend, files, opts) do
    Enum.flat_map(files, fn {path, content} ->
      {prefix, inner, stripped} = route(backend, path)

      inner
      |> Filesystem.upload_files([{stripped, content}], route_opts(opts, prefix))
      |> Enum.map(&prefix_result(&1, prefix))
    end)
  end

  @impl true
  def download_files(%__MODULE__{} = backend, paths, opts) do
    Enum.flat_map(paths, fn path ->
      {prefix, inner, stripped} = route(backend, path)

      inner
      |> Filesystem.download_files([stripped], route_opts(opts, prefix))
      |> Enum.map(&prefix_result(&1, prefix))
    end)
  end

  # Each path resolves in the backend it routes to, with one call per backend,
  # and keeps its route's prefix.
  @impl true
  def canonical_paths(%__MODULE__{} = backend, paths, opts) do
    routes = Enum.map(paths, fn path -> if is_binary(path), do: route(backend, path) end)

    canonical =
      routes
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.group_by(fn {prefix, inner, _stripped} -> {prefix, inner} end)
      |> Enum.flat_map(fn {{prefix, inner}, routed} ->
        results = Filesystem.canonical_paths(inner, Enum.map(routed, &elem(&1, 2)), route_opts(opts, prefix))
        Enum.zip(routed, Enum.map(results, &prefix_canonical(prefix, &1)))
      end)
      |> Map.new()

    Enum.map(routes, &Map.get(canonical, &1, {:error, Filesystem.invalid_path()}))
  end

  @impl BeamWeaver.Filesystem.Executable
  def id(%__MODULE__{} = backend) do
    default_id =
      if Executable.executable?(backend.default),
        do: Executable.id(backend.default),
        else: inspect(backend.default.__struct__)

    "composite:#{default_id}"
  end

  @impl BeamWeaver.Filesystem.Executable
  def execute(%__MODULE__{} = backend, command, opts) do
    if Executable.executable?(backend.default) do
      Executable.execute(backend.default, command, opts)
    else
      %Executable.ExecuteResult{exit_code: 1, error: "default backend does not support execute"}
    end
  end

  defp route(%__MODULE__{} = backend, path) do
    backend.routes
    |> Enum.sort_by(fn {prefix, _inner} -> -String.length(prefix) end)
    |> Enum.find(fn {prefix, _inner} ->
      path == String.trim_trailing(prefix, "/") or String.starts_with?(path, prefix)
    end)
    |> case do
      {prefix, inner} ->
        stripped =
          if path == String.trim_trailing(prefix, "/") do
            "/"
          else
            "/" <> String.trim_leading(String.replace_prefix(path, prefix, ""), "/")
          end

        {prefix, inner, stripped}

      nil ->
        {nil, backend.default, path}
    end
  end

  # A routed backend gets its full mount point, including the prefix of an
  # enclosing composite that routed here.
  defp route_opts(opts, nil), do: opts

  defp route_opts(opts, prefix) do
    outer = opts |> Keyword.get(:route_prefix) |> to_string() |> String.trim_trailing("/")
    Keyword.put(opts, :route_prefix, outer <> String.trim_trailing(prefix, "/"))
  end

  # Drops default-backend results under a route prefix: those paths belong to
  # the route, and the route's own results already cover them.
  defp reject_routed(%__MODULE__{routes: routes}, entries) do
    Enum.reject(entries, fn %{path: path} ->
      Enum.any?(Map.keys(routes), &(path == String.trim_trailing(&1, "/") or String.starts_with?(path, &1)))
    end)
  end

  defp normalize_prefix(prefix) do
    prefix = if String.ends_with?(prefix, "/"), do: prefix, else: prefix <> "/"
    if String.starts_with?(prefix, "/"), do: prefix, else: "/" <> prefix
  end

  defp normalize_artifacts_root(root) when is_binary(root),
    do: "/" <> (root |> String.trim() |> String.trim_leading("/") |> String.trim_trailing("/"))

  defp normalize_artifacts_root(_root), do: "/"

  # Runs `fun.(backend, glob, opts)`, a glob or grep with the glob pattern
  # `glob`, in the backends the search path reaches. A search of `/` searches
  # every backend, and fails with the first backend that fails: matches
  # without it would look complete.
  defp search(backend, glob, opts, result, sort_key, fun) do
    case route(backend, Keyword.get(opts, :path, "/")) do
      {nil, _default, path} ->
        search_with_routes(backend, path, glob, opts, result, sort_key, fun)

      {prefix, inner, stripped} ->
        inner
        |> fun.(glob, opts |> route_opts(prefix) |> Keyword.put(:path, stripped))
        |> prefix_entries(:matches, prefix)
    end
  end

  # A search of a folder of the default backend searches the routes below
  # it too. The folder may hold nothing but the way to them.
  defp search_with_routes(backend, path, glob, opts, result, sort_key, fun) do
    routes = backend.routes |> Enum.filter(fn {prefix, _inner} -> String.starts_with?(prefix, folder(path)) end)

    [{nil, backend.default} | Enum.sort(routes)]
    |> Enum.reduce_while({:ok, []}, fn {prefix, inner}, {:ok, found} ->
      {route_glob, fits?} = route_glob(glob, prefix, path)
      route_path = if prefix, do: "/", else: path

      case fun.(inner, route_glob, opts |> route_opts(prefix) |> Keyword.put(:path, route_path)) do
        %{error: nil, matches: matches} ->
          {:cont, {:ok, found ++ Enum.filter(root_matches(backend, prefix, matches || []), fits?)}}

        %{error: "file_not_found"} when is_nil(prefix) and routes != [] ->
          {:cont, {:ok, found}}

        %{error: error} ->
          {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, matches} -> %{result | matches: Enum.sort_by(matches, sort_key)}
      {:error, error} -> %{result | error: error}
    end
  end

  # The glob a route below `path` searches with, and which of its matches,
  # by their full path, fit the composite's `glob`. A pattern without `/`
  # matches names, the same in every backend. One with `/` is a path from
  # `path`: a route it starts with searches the rest, anchored to the
  # route's root. Any other route can only match it through a wildcard, so
  # it is searched for the pattern's last segment, and only its matches whose
  # path from `path` fits the pattern are kept.
  defp route_glob(glob, prefix, path) do
    relative = String.trim_leading(to_string(glob), "/")
    route = prefix && String.replace_prefix(prefix, folder(path), "")

    cond do
      is_nil(prefix) or is_nil(FsPath.grep_pattern(glob)) or not String.contains?(glob, "/") ->
        {glob, fn _match -> true end}

      String.starts_with?(relative, route) ->
        {"/" <> String.replace_prefix(relative, route, ""), fn _match -> true end}

      true ->
        {relative |> String.split("/") |> List.last(), fits(FsPath.search_pattern(glob), path)}
    end
  end

  # Whether a match's path from `path` fits `pattern`; an invalid pattern
  # fits none, and the routes' searches return its error.
  defp fits(pattern, path) do
    case FsPath.glob_matcher(pattern) do
      {:ok, match?} -> &match?.(FsPath.relative(&1.path, path))
      {:error, _invalid} -> fn _match -> false end
    end
  end

  # The default backend's matches under a route belong to the route; a route's
  # matches get its prefix.
  defp root_matches(backend, nil, matches), do: reject_routed(backend, matches)
  defp root_matches(_backend, prefix, matches), do: Enum.map(matches, &prefix_entry(&1, prefix))

  defp prefix_entries(%{error: nil} = result, field, prefix) when is_map_key(result, field),
    do: Map.update!(result, field, fn entries -> Enum.map(entries || [], &prefix_entry(&1, prefix)) end)

  defp prefix_entries(result, _field, _prefix), do: result

  defp prefix_entry(entry, prefix), do: %{entry | path: prefix_path(prefix, entry.path)}

  defp prefix_result(%{error: nil} = result, prefix), do: %{result | path: prefix_path(prefix, result.path)}
  defp prefix_result(result, _prefix), do: result

  defp prefix_canonical(prefix, {:ok, path}) when is_binary(path), do: {:ok, prefix_path(prefix, path)}
  defp prefix_canonical(_prefix, {:error, _reason} = error), do: error
  defp prefix_canonical(_prefix, _other), do: {:error, Filesystem.invalid_path()}

  defp prefix_path(nil, path), do: path

  defp prefix_path(prefix, path) do
    prefix = String.trim_trailing(prefix, "/")
    path = path || "/"

    if path == "/" do
      prefix
    else
      prefix <> "/" <> String.trim_leading(path, "/")
    end
  end
end
