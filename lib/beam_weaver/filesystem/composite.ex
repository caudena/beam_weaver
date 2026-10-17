defmodule BeamWeaver.Filesystem.Composite do
  @moduledoc """
  Routes virtual path prefixes to different filesystem backends, with a default
  backend for other paths.

  A routed backend sees paths without the route's prefix (`/policies/refunds.md`
  reaches the `/policies/` backend as `/refunds.md`) and gets the prefix as the
  `:route_prefix` option, so a backend that stores files in the shared graph
  state, such as `BeamWeaver.Filesystem.State`, keeps them under their full
  path. Paths under a route belong to it: listing or searching `/` takes them
  from the route, not from the default backend.
  """

  use BeamWeaver.Filesystem
  use BeamWeaver.Filesystem.Executable

  alias BeamWeaver.Filesystem
  alias BeamWeaver.Filesystem.Executable
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
  def ls(%__MODULE__{} = backend, "/", opts) do
    default_entries =
      backend.default
      |> Filesystem.ls("/", opts)
      |> case do
        %Filesystem.LsResult{error: nil, entries: entries} -> reject_routed(backend, entries || [])
        _error -> []
      end

    route_entries =
      backend.routes
      |> Map.keys()
      |> Enum.sort()
      |> Enum.map(fn prefix ->
        %Filesystem.FileInfo{path: String.trim_trailing(prefix, "/"), is_dir: true}
      end)

    %Filesystem.LsResult{entries: Enum.uniq_by(default_entries ++ route_entries, & &1.path)}
  end

  @impl true
  def ls(%__MODULE__{} = backend, path, opts) do
    {prefix, inner, stripped} = route(backend, path)

    inner
    |> Filesystem.ls(stripped, route_opts(opts, prefix))
    |> prefix_entries(:entries, prefix)
  end

  @impl true
  def read(%__MODULE__{} = backend, path, opts) do
    {prefix, inner, stripped} = route(backend, path)
    Filesystem.read(inner, stripped, route_opts(opts, prefix))
  end

  @impl true
  def glob(%__MODULE__{} = backend, pattern, opts),
    do: search(backend, &Filesystem.glob/3, pattern, opts, %Filesystem.GlobResult{}, & &1.path)

  @impl true
  def grep(%__MODULE__{} = backend, pattern, opts),
    do: search(backend, &Filesystem.grep/3, pattern, opts, %Filesystem.GrepResult{}, &{&1.path, &1.line})

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
      %Executable.ExecuteResult{
        exit_code: 1,
        output: "",
        error: "default backend does not support execute",
        truncated: false
      }
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

  defp normalize_artifacts_root(root) when is_binary(root) do
    root
    |> String.trim()
    |> case do
      "" -> "/"
      "/" -> "/"
      root -> "/" <> (root |> String.trim_leading("/") |> String.trim_trailing("/"))
    end
  end

  defp normalize_artifacts_root(_root), do: "/"

  defp search(backend, fun, pattern, opts, result, sort_key) do
    case Keyword.get(opts, :path, "/") do
      "/" ->
        default_matches =
          backend.default
          |> fun.(pattern, Keyword.put(opts, :path, "/"))
          |> matches()
          |> then(&reject_routed(backend, &1))

        route_matches =
          Enum.flat_map(backend.routes, fn {prefix, inner} ->
            inner
            |> fun.(pattern, opts |> route_opts(prefix) |> Keyword.put(:path, "/"))
            |> matches()
            |> Enum.map(&prefix_entry(&1, prefix))
          end)

        %{result | matches: Enum.sort_by(default_matches ++ route_matches, sort_key)}

      path ->
        {prefix, inner, stripped} = route(backend, path)

        inner
        |> fun.(pattern, opts |> route_opts(prefix) |> Keyword.put(:path, stripped))
        |> prefix_entries(:matches, prefix)
    end
  end

  defp matches(%{error: nil, matches: matches}), do: matches || []
  defp matches(_result), do: []

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
