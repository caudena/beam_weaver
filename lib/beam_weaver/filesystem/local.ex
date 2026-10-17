defmodule BeamWeaver.Filesystem.Local do
  @moduledoc "Virtual-root filesystem backend for trusted local development and CI."

  use BeamWeaver.Filesystem

  alias BeamWeaver.Filesystem
  alias BeamWeaver.Filesystem.Edit
  alias BeamWeaver.Filesystem.FileDataUtils
  alias BeamWeaver.Filesystem.Path, as: FsPath

  defstruct [:root, max_binary_preview: 512_000]

  def new(opts \\ []) do
    root = Keyword.get(opts, :root, Keyword.get(opts, :root_dir))
    if is_nil(root), do: raise(ArgumentError, "filesystem backend requires :root or :root_dir")
    root = Path.expand(root)
    File.mkdir_p!(root)
    %__MODULE__{root: root, max_binary_preview: Keyword.get(opts, :max_binary_preview, 512_000)}
  end

  @impl true
  def ls(%__MODULE__{} = backend, path, _opts) do
    real_root = FsPath.real_root(backend.root)

    with {:ok, real, virtual} <- FsPath.resolve_virtual(real_root, path),
         true <- File.dir?(real),
         {:ok, names} <- File.ls(real) do
      entries =
        names
        |> Enum.sort()
        |> Enum.flat_map(&reachable(real_root, virtual, &1))
        |> Enum.map(&file_info/1)

      %Filesystem.LsResult{entries: entries}
    else
      false -> %Filesystem.LsResult{entries: []}
      {:error, reason} -> %Filesystem.LsResult{error: FileDataUtils.error_string(reason)}
    end
  end

  @impl true
  def read(%__MODULE__{} = backend, path, opts) do
    with {:ok, real, virtual} <- FsPath.virtual_to_real(backend.root, path),
         {:ok, data} <-
           FileDataUtils.encode_disk_file(
             real,
             virtual,
             Keyword.put(opts, :max_binary_preview, backend.max_binary_preview)
           ) do
      %Filesystem.ReadResult{file_data: data}
    else
      {:error, reason} -> %Filesystem.ReadResult{error: FileDataUtils.error_string(reason)}
    end
  end

  @impl true
  def write(%__MODULE__{} = backend, path, content, _opts) do
    with {:ok, real, virtual} <- FsPath.virtual_to_real(backend.root, path),
         false <- File.exists?(real),
         :ok <- File.mkdir_p(Path.dirname(real)),
         :ok <- File.write(real, IO.iodata_to_binary(content)) do
      %Filesystem.WriteResult{path: virtual}
    else
      true -> %Filesystem.WriteResult{path: path, error: "file already exists"}
      {:error, reason} -> %Filesystem.WriteResult{path: path, error: FileDataUtils.error_string(reason)}
    end
  end

  @impl true
  def edit(%__MODULE__{} = backend, path, old, new, opts) do
    with {:ok, real, virtual} <- FsPath.virtual_to_real(backend.root, path),
         {:ok, content} <- File.read(real),
         {:ok, occurrences, updated} <- Edit.replacement(content, old, new, Keyword.get(opts, :replace_all, false)),
         :ok <- File.write(real, updated) do
      %Filesystem.EditResult{path: virtual, occurrences: occurrences}
    else
      {:error, :not_found} ->
        %Filesystem.EditResult{path: path, occurrences: 0, error: "string not found"}

      {:error, error} ->
        %Filesystem.EditResult{path: path, error: FileDataUtils.error_string(error)}
    end
  end

  @impl true
  def glob(%__MODULE__{} = backend, pattern, opts) do
    case matches(backend, Keyword.get(opts, :path, "/"), pattern) do
      {:ok, matches} -> %Filesystem.GlobResult{matches: Enum.map(matches, &file_info/1)}
      {:error, reason} -> %Filesystem.GlobResult{error: FileDataUtils.error_string(reason)}
    end
  end

  @impl true
  def grep(%__MODULE__{} = backend, pattern, opts) do
    case matches(backend, Keyword.get(opts, :path, "/"), Keyword.get(opts, :glob) || "**/*") do
      {:ok, files} -> %Filesystem.GrepResult{matches: Enum.flat_map(files, &grep_file(&1, pattern))}
      {:error, reason} -> %Filesystem.GrepResult{error: FileDataUtils.error_string(reason)}
    end
  end

  @impl true
  def upload_files(%__MODULE__{} = backend, files, _opts) do
    Enum.map(files, fn {path, content} ->
      with {:ok, real, virtual} <- FsPath.virtual_to_real(backend.root, path),
           :ok <- File.mkdir_p(Path.dirname(real)),
           :ok <- File.write(real, IO.iodata_to_binary(content)) do
        %Filesystem.UploadResult{path: virtual}
      else
        {:error, reason} ->
          %Filesystem.UploadResult{path: path, error: FileDataUtils.error_string(reason)}
      end
    end)
  end

  @impl true
  def download_files(%__MODULE__{} = backend, paths, _opts) do
    Enum.map(paths, fn path ->
      with {:ok, real, virtual} <- FsPath.virtual_to_real(backend.root, path),
           false <- File.dir?(real),
           {:ok, content} <- File.read(real) do
        %Filesystem.DownloadResult{path: virtual, content: content}
      else
        true ->
          %Filesystem.DownloadResult{path: path, error: "is_directory"}

        {:error, reason} ->
          %Filesystem.DownloadResult{path: path, error: FileDataUtils.error_string(reason)}
      end
    end)
  end

  # A path's canonical path is the real path the other callbacks open for it,
  # relative to the root.
  @impl true
  def canonical_paths(%__MODULE__{} = backend, paths, _opts) do
    real_root = FsPath.real_root(backend.root)
    Enum.map(paths, &FsPath.canonical_path(real_root, &1))
  end

  # The files under the virtual directory `path` that match `pattern`, as
  # `{real_path, virtual_path}` pairs. The directory's own name is never read
  # as a pattern, and matches the file tools can't open, such as symlinks to
  # files outside the root, are left out.
  defp matches(backend, path, pattern) do
    real_root = FsPath.real_root(backend.root)

    with {:ok, real, virtual} <- FsPath.resolve_virtual(real_root, path),
         {:ok, pattern} <- FsPath.clean_pattern(pattern),
         {:ok, relative_paths} <- wildcard(String.trim_leading(pattern, "/"), real) do
      matches =
        relative_paths
        |> Enum.flat_map(&reachable(real_root, virtual, &1))
        |> Enum.sort_by(fn {_real, match} -> match end)

      {:ok, matches}
    end
  end

  defp wildcard("", _dir), do: {:ok, []}

  defp wildcard(pattern, dir) do
    relative_paths =
      pattern
      |> String.to_charlist()
      |> :filelib.wildcard(String.to_charlist(dir))
      |> Enum.map(&IO.chardata_to_string/1)

    {:ok, relative_paths}
  rescue
    error in ErlangError ->
      if match?({:badpattern, _reason}, error.original),
        do: {:error, "invalid_pattern"},
        else: reraise(error, __STACKTRACE__)
  end

  # `relative` under the virtual directory `dir`, or nothing when the file
  # tools couldn't open it: a symlink to a file outside the root, say.
  defp reachable(real_root, dir, relative) do
    case FsPath.resolve_virtual(real_root, Path.join(dir, relative)) do
      {:ok, real, virtual} -> [{real, virtual}]
      {:error, _reason} -> []
    end
  end

  defp file_info({real, virtual}) do
    case File.stat(real) do
      {:ok, %File.Stat{type: :directory}} -> %Filesystem.FileInfo{path: virtual, is_dir: true}
      {:ok, %File.Stat{type: :regular, size: size}} -> %Filesystem.FileInfo{path: virtual, is_dir: false, size: size}
      _other -> %Filesystem.FileInfo{path: virtual, is_dir: false}
    end
  end

  defp grep_file({real, virtual}, pattern) do
    with false <- File.dir?(real),
         {:ok, content} <- File.read(real) do
      for {line, number} <- content |> String.split("\n") |> Enum.with_index(1),
          String.contains?(line, pattern),
          do: %Filesystem.GrepMatch{path: virtual, line: number, text: line}
    else
      _directory_or_error -> []
    end
  end
end
