defmodule BeamWeaver.Filesystem.State do
  @moduledoc "Thread-scoped backend backed by BeamWeaver graph state."

  use BeamWeaver.Filesystem

  alias BeamWeaver.Filesystem
  alias BeamWeaver.Filesystem.Edit
  alias BeamWeaver.Filesystem.Utils

  defstruct state_key: :files

  def new(opts \\ []), do: %__MODULE__{state_key: Keyword.get(opts, :state_key, :files)}

  @impl true
  def ls(%__MODULE__{} = backend, path, opts) do
    case Utils.clean_path(path) do
      {:ok, path} ->
        %Filesystem.LsResult{entries: backend |> files(opts) |> Utils.immediate_entries(path)}

      {:error, error} ->
        %Filesystem.LsResult{error: error}
    end
  end

  @impl true
  def read(%__MODULE__{} = backend, path, opts) do
    with {:ok, path} <- Utils.clean_path(path),
         {:ok, data} <- fetch_file(files(backend, opts), path),
         {:ok, content} <- data |> Utils.normalize_file_data() |> Utils.read_content(opts) do
      %Filesystem.ReadResult{file_data: %{Utils.normalize_file_data(data) | content: content}}
    else
      {:error, error} -> %Filesystem.ReadResult{error: error}
    end
  end

  @impl true
  def write(%__MODULE__{} = backend, path, content, opts) do
    with {:ok, path} <- Utils.clean_path(path),
         files <- files(backend, opts),
         false <- Map.has_key?(files, path) do
      updated =
        Map.put(files, path, Utils.file_data(IO.iodata_to_binary(content), encoding: "utf-8"))

      %Filesystem.WriteResult{path: path, files_update: updated}
    else
      true -> %Filesystem.WriteResult{path: path, error: "file already exists"}
      {:error, error} -> %Filesystem.WriteResult{path: path, error: error}
    end
  end

  @impl true
  def edit(%__MODULE__{} = backend, path, old, new, opts) do
    replace_all? = Keyword.get(opts, :replace_all, false)

    with {:ok, path} <- Utils.clean_path(path),
         files <- files(backend, opts),
         {:ok, data} <- fetch_file(files, path),
         %Filesystem.FileData{encoding: "utf-8", content: content} = data <-
           Utils.normalize_file_data(data),
         {:ok, occurrences, updated_content} <- Edit.replacement(content, old, new, replace_all?) do
      updated_data = %{data | content: updated_content, modified_at: Utils.now()}

      %Filesystem.EditResult{
        path: path,
        occurrences: occurrences,
        files_update: Map.put(files, path, updated_data)
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
    case Utils.clean_path(Keyword.get(opts, :path, "/")) do
      {:ok, path} ->
        %Filesystem.GlobResult{
          matches: backend |> files(opts) |> Utils.glob_files(pattern, path: path)
        }

      {:error, error} ->
        %Filesystem.GlobResult{error: error}
    end
  end

  @impl true
  def grep(%__MODULE__{} = backend, pattern, opts) do
    case Utils.clean_path(Keyword.get(opts, :path, "/")) do
      {:ok, path} ->
        matches =
          backend
          |> files(opts)
          |> Utils.grep_files(pattern, path: path, glob: Keyword.get(opts, :glob))

        %Filesystem.GrepResult{matches: matches}

      {:error, error} ->
        %Filesystem.GrepResult{error: error}
    end
  end

  @impl true
  def upload_files(%__MODULE__{} = backend, uploaded, opts) do
    files = files(backend, opts)

    {_files, results} =
      Enum.reduce(uploaded, {files, []}, fn {path, content}, {files, results} ->
        case Utils.clean_path(path) do
          {:ok, path} ->
            data = Utils.file_data_from_upload(content)
            {Map.put(files, path, data), [%Filesystem.UploadResult{path: path} | results]}

          {:error, error} ->
            {files, [%Filesystem.UploadResult{path: path, error: error} | results]}
        end
      end)

    Enum.reverse(results)
  end

  @impl true
  def download_files(%__MODULE__{} = backend, paths, opts) do
    files = files(backend, opts)

    Enum.map(paths, fn path ->
      with {:ok, path} <- Utils.clean_path(path),
           {:ok, data} <- fetch_file(files, path),
           %Filesystem.FileData{} = data <- Utils.normalize_file_data(data),
           {:ok, content} <- decode_download(data) do
        %Filesystem.DownloadResult{path: path, content: content}
      else
        nil -> %Filesystem.DownloadResult{path: path, error: "invalid_file_data"}
        {:error, error} -> %Filesystem.DownloadResult{path: path, error: error}
      end
    end)
  end

  defp files(%__MODULE__{state_key: state_key}, opts) do
    state = Keyword.get(opts, :state, %{}) || %{}
    Map.get(state, state_key, Map.get(state, to_string(state_key), %{})) || %{}
  end

  defp fetch_file(files, path) do
    case Map.fetch(files, path) do
      {:ok, data} -> {:ok, data}
      :error -> {:error, "file_not_found"}
    end
  end

  defp decode_download(%Filesystem.FileData{encoding: "base64", content: content}),
    do: Base.decode64(content)

  defp decode_download(%Filesystem.FileData{content: content}), do: {:ok, content || ""}
end
