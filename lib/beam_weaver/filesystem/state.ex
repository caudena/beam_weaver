defmodule BeamWeaver.Filesystem.State do
  @moduledoc """
  Thread-scoped backend backed by BeamWeaver graph state.

  Files live in the run's state under `:state_key` (default `:files`), keyed by
  their path. The backend never changes the state itself: `write/4` and
  `edit/5` return the file they changed in their result's `files_update`, as
  `%{path => file_data}`, which the file tools merge into the state's files,
  so changes to different files in one step all apply. `upload_files/3`
  can't store anything for the same reason and returns an error for every
  file: pass files in the agent's input as `files: %{"/notes.md" => "..."}`,
  or set them with `BeamWeaver.Graph.Compiled.update_state/4`.

  Under a `BeamWeaver.Filesystem.Composite` route, the composite passes the
  route's prefix as the `:route_prefix` option: the backend then sees only the
  files under that prefix, and keeps the files it writes under their full
  path, such as `/scratch/notes.md` for `/notes.md`.
  """

  use BeamWeaver.Filesystem

  alias BeamWeaver.Filesystem
  alias BeamWeaver.Filesystem.Edit
  alias BeamWeaver.Filesystem.FileDataUtils
  alias BeamWeaver.Filesystem.Path, as: FsPath
  alias BeamWeaver.Filesystem.Search

  @upload_error "Filesystem.State can't upload files: they live in the thread's state. " <>
                  "Pass them in the agent's input as files: %{path => content}, " <>
                  "or set them with BeamWeaver.Graph.Compiled.update_state/4."

  defstruct state_key: :files

  def new(opts \\ []), do: %__MODULE__{state_key: Keyword.get(opts, :state_key, :files)}

  @impl true
  def ls(%__MODULE__{} = backend, path, opts) do
    case FsPath.clean_path(path) do
      {:ok, path} ->
        files = visible_files(backend, opts)

        if exists?(files, path),
          do: %Filesystem.LsResult{entries: Search.immediate_entries(files, path)},
          else: %Filesystem.LsResult{error: "file_not_found"}

      {:error, error} ->
        %Filesystem.LsResult{error: error}
    end
  end

  @impl true
  def read(%__MODULE__{} = backend, path, opts) do
    with {:ok, path} <- FsPath.clean_path(path),
         {:ok, data} <- fetch_file(files(backend, opts), state_path(path, opts)),
         data = FileDataUtils.normalize_file_data(data),
         {:ok, content} <- FileDataUtils.read_content(data, opts) do
      %Filesystem.ReadResult{file_data: %{data | content: content}}
    else
      {:error, error} -> %Filesystem.ReadResult{error: error}
    end
  end

  # Writes the file as text, replacing one that exists; a file it replaces
  # keeps when it was created.
  @impl true
  def write(%__MODULE__{} = backend, path, content, opts) do
    case FsPath.clean_path(path) do
      {:ok, path} ->
        key = state_path(path, opts)
        now = FileDataUtils.now()
        replaced = backend |> files(opts) |> Map.get(key) |> FileDataUtils.normalize_file_data()
        created_at = (replaced && replaced.created_at) || now

        file_data =
          FileDataUtils.file_data(IO.iodata_to_binary(content), encoding: "utf-8", now: now, created_at: created_at)

        %Filesystem.WriteResult{path: path, files_update: %{key => file_data}}

      {:error, error} ->
        %Filesystem.WriteResult{path: path, error: error}
    end
  end

  @impl true
  def edit(%__MODULE__{} = backend, path, old, new, opts) do
    replace_all? = Keyword.get(opts, :replace_all, false)

    with {:ok, path} <- FsPath.clean_path(path),
         files = files(backend, opts),
         key = state_path(path, opts),
         {:ok, data} <- fetch_file(files, key),
         %Filesystem.FileData{encoding: "utf-8", content: content} = data <-
           FileDataUtils.normalize_file_data(data),
         {:ok, occurrences, updated_content} <- Edit.replacement(content, old, new, replace_all?) do
      updated_data = %{data | content: updated_content, modified_at: FileDataUtils.now()}

      %Filesystem.EditResult{
        path: path,
        occurrences: occurrences,
        files_update: %{key => updated_data}
      }
    else
      nil ->
        %Filesystem.EditResult{path: path, error: "invalid_file_data"}

      {:error, :not_found} ->
        %Filesystem.EditResult{path: path, occurrences: 0, error: "string not found"}

      {:error, error} ->
        %Filesystem.EditResult{path: path, error: error}
    end
  end

  @impl true
  def glob(%__MODULE__{} = backend, pattern, opts) do
    with {:ok, path} <- FsPath.clean_path(Keyword.get(opts, :path, "/")),
         files = visible_files(backend, opts),
         true <- exists?(files, path) || {:error, "file_not_found"},
         {:ok, matches} <- Search.glob_files(files, pattern, path: path) do
      %Filesystem.GlobResult{matches: matches}
    else
      {:error, error} -> %Filesystem.GlobResult{error: error}
    end
  end

  @impl true
  def grep(%__MODULE__{} = backend, pattern, opts) do
    with {:ok, path} <- FsPath.clean_path(Keyword.get(opts, :path, "/")),
         files = visible_files(backend, opts),
         true <- exists?(files, path) || {:error, "file_not_found"},
         {:ok, matches} <- Search.grep_files(files, pattern, path: path, glob: Keyword.get(opts, :glob)) do
      %Filesystem.GrepResult{matches: matches}
    else
      {:error, error} -> %Filesystem.GrepResult{error: error}
    end
  end

  @impl true
  def upload_files(%__MODULE__{}, files, _opts) do
    Enum.map(files, fn {path, _content} -> %Filesystem.UploadResult{path: path, error: @upload_error} end)
  end

  @impl true
  def download_files(%__MODULE__{} = backend, paths, opts) do
    files = files(backend, opts)

    Enum.map(paths, fn path ->
      with {:ok, path} <- FsPath.clean_path(path),
           {:ok, data} <- fetch_file(files, state_path(path, opts)),
           %Filesystem.FileData{} = data <- FileDataUtils.normalize_file_data(data),
           {:ok, content} <- decode_download(data) do
        %Filesystem.DownloadResult{path: path, content: content}
      else
        {:error, error} -> %Filesystem.DownloadResult{path: path, error: error}
        _invalid -> %Filesystem.DownloadResult{path: path, error: "invalid_file_data"}
      end
    end)
  end

  defp files(%__MODULE__{state_key: state_key}, opts) do
    state = Keyword.get(opts, :state, %{}) || %{}
    Map.get(state, state_key, Map.get(state, to_string(state_key), %{})) || %{}
  end

  # The files this backend can see, by the paths its callers use: all of them,
  # or under a route prefix only those below it, without the prefix.
  # A path exists when it is `/`, a file, or a folder that holds a file.
  defp exists?(_files, "/"), do: true
  defp exists?(files, path), do: Enum.any?(Map.keys(files), &FsPath.under_path?(&1, path))

  defp visible_files(backend, opts) do
    files = files(backend, opts)

    case route_prefix(opts) do
      nil ->
        files

      prefix ->
        for {key, data} <- files, String.starts_with?(key, prefix <> "/"), into: %{} do
          {String.replace_prefix(key, prefix, ""), data}
        end
    end
  end

  # The state key of `path`.
  defp state_path(path, opts) do
    case route_prefix(opts) do
      nil -> path
      prefix when path == "/" -> prefix
      prefix -> prefix <> path
    end
  end

  defp route_prefix(opts) do
    case opts |> Keyword.get(:route_prefix) |> to_string() |> String.trim_trailing("/") do
      "" -> nil
      prefix -> prefix
    end
  end

  defp fetch_file(files, path) do
    with :error <- Map.fetch(files, path), do: {:error, "file_not_found"}
  end

  defp decode_download(%Filesystem.FileData{encoding: "base64", content: content}),
    do: Base.decode64(content)

  defp decode_download(%Filesystem.FileData{content: content}), do: {:ok, content || ""}
end
