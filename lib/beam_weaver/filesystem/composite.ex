defmodule BeamWeaver.Filesystem.Composite do
  @moduledoc "Routes virtual path prefixes to different DeepAgents backends."

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
        %Filesystem.LsResult{error: nil, entries: entries} -> entries || []
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
    |> Filesystem.ls(stripped, opts)
    |> prefix_ls_result(prefix)
  end

  @impl true
  def read(%__MODULE__{} = backend, path, opts) do
    {_prefix, inner, stripped} = route(backend, path)
    Filesystem.read(inner, stripped, opts)
  end

  @impl true
  def glob(%__MODULE__{} = backend, pattern, opts) do
    path = Keyword.get(opts, :path, "/")

    if path == "/" do
      default_matches =
        backend.default
        |> Filesystem.glob(pattern, Keyword.put(opts, :path, "/"))
        |> glob_matches()

      route_matches =
        backend.routes
        |> Enum.flat_map(fn {prefix, inner} ->
          inner
          |> Filesystem.glob(pattern, Keyword.put(opts, :path, "/"))
          |> glob_matches()
          |> Enum.map(&prefix_file_info(prefix, &1))
        end)

      %Filesystem.GlobResult{matches: Enum.sort_by(default_matches ++ route_matches, & &1.path)}
    else
      {prefix, inner, stripped} = route(backend, path)

      inner
      |> Filesystem.glob(pattern, Keyword.put(opts, :path, stripped))
      |> prefix_glob_result(prefix)
    end
  end

  @impl true
  def grep(%__MODULE__{} = backend, pattern, opts) do
    path = Keyword.get(opts, :path, "/")

    if path == "/" do
      default_matches =
        backend.default
        |> Filesystem.grep(pattern, Keyword.put(opts, :path, "/"))
        |> grep_matches()

      route_matches =
        backend.routes
        |> Enum.flat_map(fn {prefix, inner} ->
          inner
          |> Filesystem.grep(pattern, Keyword.put(opts, :path, "/"))
          |> grep_matches()
          |> Enum.map(&prefix_grep_match(prefix, &1))
        end)

      %Filesystem.GrepResult{
        matches: Enum.sort_by(default_matches ++ route_matches, &{&1.path, &1.line})
      }
    else
      {prefix, inner, stripped} = route(backend, path)

      inner
      |> Filesystem.grep(pattern, Keyword.put(opts, :path, stripped))
      |> prefix_grep_result(prefix)
    end
  end

  @impl true
  def write(%__MODULE__{} = backend, path, content, opts) do
    {prefix, inner, stripped} = route(backend, path)

    inner
    |> Filesystem.write(stripped, content, opts)
    |> prefix_write_result(prefix)
  end

  @impl true
  def edit(%__MODULE__{} = backend, path, old, new, opts) do
    {prefix, inner, stripped} = route(backend, path)

    inner
    |> Filesystem.edit(stripped, old, new, opts)
    |> prefix_edit_result(prefix)
  end

  @impl true
  def upload_files(%__MODULE__{} = backend, files, opts) do
    Enum.flat_map(files, fn {path, content} ->
      {prefix, inner, stripped} = route(backend, path)

      inner
      |> Filesystem.upload_files([{stripped, content}], opts)
      |> Enum.map(&prefix_upload_result(prefix, &1))
    end)
  end

  @impl true
  def download_files(%__MODULE__{} = backend, paths, opts) do
    Enum.flat_map(paths, fn path ->
      {prefix, inner, stripped} = route(backend, path)

      inner
      |> Filesystem.download_files([stripped], opts)
      |> Enum.map(&prefix_download_result(prefix, &1))
    end)
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

  defp prefix_ls_result(%Filesystem.LsResult{error: nil, entries: entries} = result, prefix),
    do: %{result | entries: Enum.map(entries || [], &prefix_file_info(prefix, &1))}

  defp prefix_ls_result(result, _prefix), do: result

  defp prefix_glob_result(%Filesystem.GlobResult{error: nil, matches: matches} = result, prefix),
    do: %{result | matches: Enum.map(matches || [], &prefix_file_info(prefix, &1))}

  defp prefix_glob_result(result, _prefix), do: result

  defp prefix_grep_result(%Filesystem.GrepResult{error: nil, matches: matches} = result, prefix),
    do: %{result | matches: Enum.map(matches || [], &prefix_grep_match(prefix, &1))}

  defp prefix_grep_result(result, _prefix), do: result

  defp prefix_write_result(%Filesystem.WriteResult{error: nil} = result, prefix),
    do: %{result | path: prefix_path(prefix, result.path)}

  defp prefix_write_result(result, _prefix), do: result

  defp prefix_edit_result(%Filesystem.EditResult{error: nil} = result, prefix),
    do: %{result | path: prefix_path(prefix, result.path)}

  defp prefix_edit_result(result, _prefix), do: result

  defp prefix_upload_result(prefix, %Filesystem.UploadResult{error: nil} = result),
    do: %{result | path: prefix_path(prefix, result.path)}

  defp prefix_upload_result(_prefix, result), do: result

  defp prefix_download_result(prefix, %Filesystem.DownloadResult{error: nil} = result),
    do: %{result | path: prefix_path(prefix, result.path)}

  defp prefix_download_result(_prefix, result), do: result

  defp prefix_file_info(nil, %Filesystem.FileInfo{} = info), do: info

  defp prefix_file_info(prefix, %Filesystem.FileInfo{} = info),
    do: %{info | path: prefix_path(prefix, info.path)}

  defp prefix_grep_match(nil, %Filesystem.GrepMatch{} = match), do: match

  defp prefix_grep_match(prefix, %Filesystem.GrepMatch{} = match),
    do: %{match | path: prefix_path(prefix, match.path)}

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

  defp glob_matches(%Filesystem.GlobResult{error: nil, matches: matches}), do: matches || []
  defp glob_matches(_result), do: []

  defp grep_matches(%Filesystem.GrepResult{error: nil, matches: matches}), do: matches || []
  defp grep_matches(_result), do: []
end
