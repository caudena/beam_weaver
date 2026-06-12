defmodule BeamWeaver.Filesystem.Local do
  @moduledoc "Virtual-root filesystem backend for trusted local development and CI."

  use BeamWeaver.Filesystem

  alias BeamWeaver.Filesystem
  alias BeamWeaver.Filesystem.Edit
  alias BeamWeaver.Filesystem.Utils

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
    with {:ok, real, virtual} <- Utils.virtual_to_real(backend.root, path),
         true <- File.dir?(real),
         {:ok, names} <- File.ls(real) do
      entries =
        names
        |> Enum.sort()
        |> Enum.map(fn name ->
          full = Path.join(real, name)

          %Filesystem.FileInfo{
            path: Path.join(virtual, name),
            is_dir: File.dir?(full),
            size: if(File.regular?(full), do: File.stat!(full).size)
          }
        end)

      %Filesystem.LsResult{entries: entries}
    else
      false -> %Filesystem.LsResult{entries: []}
      {:error, reason} -> %Filesystem.LsResult{error: Utils.error_string(reason)}
    end
  end

  @impl true
  def read(%__MODULE__{} = backend, path, opts) do
    with {:ok, real, virtual} <- Utils.virtual_to_real(backend.root, path),
         {:ok, data} <-
           Utils.encode_disk_file(
             real,
             virtual,
             Keyword.put(opts, :max_binary_preview, backend.max_binary_preview)
           ) do
      %Filesystem.ReadResult{file_data: data}
    else
      {:error, reason} -> %Filesystem.ReadResult{error: Utils.error_string(reason)}
    end
  end

  @impl true
  def write(%__MODULE__{} = backend, path, content, _opts) do
    with {:ok, real, virtual} <- Utils.virtual_to_real(backend.root, path),
         false <- File.exists?(real),
         :ok <- File.mkdir_p(Path.dirname(real)),
         :ok <- File.write(real, IO.iodata_to_binary(content)) do
      %Filesystem.WriteResult{path: virtual}
    else
      true -> %Filesystem.WriteResult{path: path, error: "file already exists"}
      {:error, reason} -> %Filesystem.WriteResult{path: path, error: Utils.error_string(reason)}
    end
  end

  @impl true
  def edit(%__MODULE__{} = backend, path, old, new, opts) do
    replace_all? = Keyword.get(opts, :replace_all, false)

    with {:ok, real, virtual} <- Utils.virtual_to_real(backend.root, path),
         {:ok, content} <- File.read(real),
         {:ok, occurrences, updated} <- Edit.replacement(content, old, new, replace_all?),
         :ok <- File.write(real, updated) do
      %Filesystem.EditResult{
        path: virtual,
        occurrences: if(replace_all?, do: occurrences, else: 1)
      }
    else
      {:error, :not_found} ->
        %Filesystem.EditResult{path: path, occurrences: 0, error: "string not found"}

      {:error, error} ->
        %Filesystem.EditResult{path: path, error: Utils.error_string(error)}
    end
  end

  @impl true
  def glob(%__MODULE__{} = backend, pattern, opts) do
    base = Keyword.get(opts, :path, "/")

    case Utils.virtual_to_real(backend.root, base) do
      {:ok, real, virtual_base} ->
        matches =
          real
          |> Path.join(pattern)
          |> Path.wildcard(match_dot: true)
          |> Enum.sort()
          |> Enum.map(fn path ->
            %Filesystem.FileInfo{
              path: Path.join(virtual_base, Path.relative_to(path, real)),
              is_dir: File.dir?(path),
              size: if(File.regular?(path), do: File.stat!(path).size)
            }
          end)

        %Filesystem.GlobResult{matches: matches}

      {:error, reason} ->
        %Filesystem.GlobResult{error: Utils.error_string(reason)}
    end
  end

  @impl true
  def grep(%__MODULE__{} = backend, pattern, opts) do
    base = Keyword.get(opts, :path, "/")
    include = Keyword.get(opts, :glob, "**/*")

    case Utils.virtual_to_real(backend.root, base) do
      {:ok, real, virtual_base} ->
        matches =
          real
          |> Path.join(include)
          |> Path.wildcard(match_dot: true)
          |> Enum.reject(&File.dir?/1)
          |> Enum.flat_map(fn path ->
            case File.read(path) do
              {:ok, content} ->
                content
                |> String.split("\n")
                |> Enum.with_index(1)
                |> Enum.flat_map(fn {line, line_number} ->
                  if String.contains?(line, pattern) do
                    [
                      %Filesystem.GrepMatch{
                        path: Path.join(virtual_base, Path.relative_to(path, real)),
                        line: line_number,
                        text: line
                      }
                    ]
                  else
                    []
                  end
                end)

              _error ->
                []
            end
          end)

        %Filesystem.GrepResult{matches: matches}

      {:error, reason} ->
        %Filesystem.GrepResult{error: Utils.error_string(reason)}
    end
  end

  @impl true
  def upload_files(%__MODULE__{} = backend, files, _opts) do
    Enum.map(files, fn {path, content} ->
      with {:ok, real, virtual} <- Utils.virtual_to_real(backend.root, path),
           :ok <- File.mkdir_p(Path.dirname(real)),
           :ok <- File.write(real, IO.iodata_to_binary(content)) do
        %Filesystem.UploadResult{path: virtual}
      else
        {:error, reason} ->
          %Filesystem.UploadResult{path: path, error: Utils.error_string(reason)}
      end
    end)
  end

  @impl true
  def download_files(%__MODULE__{} = backend, paths, _opts) do
    Enum.map(paths, fn path ->
      with {:ok, real, virtual} <- Utils.virtual_to_real(backend.root, path),
           false <- File.dir?(real),
           {:ok, content} <- File.read(real) do
        %Filesystem.DownloadResult{path: virtual, content: content}
      else
        true ->
          %Filesystem.DownloadResult{path: path, error: "is_directory"}

        {:error, reason} ->
          %Filesystem.DownloadResult{path: path, error: Utils.error_string(reason)}
      end
    end)
  end
end
