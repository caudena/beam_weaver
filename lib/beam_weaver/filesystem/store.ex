defmodule BeamWeaver.Filesystem.Store do
  @moduledoc """
  Backend that stores files in a BeamWeaver long-term memory store.

  Each file is one item in the `:namespace`, keyed by its path without the
  leading `/`, with a JSON-safe map as its value (`"content"`, `"encoding"`,
  `"created_at"` and `"modified_at"`), so it works with every
  `BeamWeaver.Memory.Store`, including `BeamWeaver.Memory.Ecto`. Pass the store
  as `:store`, or per call in the options. A failed store read or write comes
  back in the result's `error`.
  """

  use BeamWeaver.Filesystem

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Filesystem
  alias BeamWeaver.Filesystem.FileData
  alias BeamWeaver.Filesystem.FileDataUtils
  alias BeamWeaver.Filesystem.State
  alias BeamWeaver.Memory

  @missing_store "missing_store"

  defstruct namespace: ["deepagents", "files"], store: nil

  def new(opts \\ []) do
    %__MODULE__{
      namespace: normalize_namespace_or_factory(Keyword.get(opts, :namespace, ["deepagents", "files"])),
      store: Keyword.get(opts, :store)
    }
  end

  @impl true
  def ls(%__MODULE__{} = backend, path, opts) do
    with_files(backend, opts, &State.ls(State.new(), path, &1), &%Filesystem.LsResult{error: &1})
  end

  @impl true
  def read(%__MODULE__{} = backend, path, opts) do
    with_files(backend, opts, &State.read(State.new(), path, &1), &%Filesystem.ReadResult{error: &1})
  end

  @impl true
  def write(%__MODULE__{} = backend, path, content, opts) do
    with_files(
      backend,
      opts,
      &(State.new() |> State.write(path, content, &1) |> persist(backend, opts)),
      &%Filesystem.WriteResult{path: path, error: &1}
    )
  end

  @impl true
  def edit(%__MODULE__{} = backend, path, old, new, opts) do
    with_files(
      backend,
      opts,
      &(State.new() |> State.edit(path, old, new, &1) |> persist(backend, opts)),
      &%Filesystem.EditResult{path: path, error: &1}
    )
  end

  @impl true
  def glob(%__MODULE__{} = backend, pattern, opts) do
    with_files(backend, opts, &State.glob(State.new(), pattern, &1), &%Filesystem.GlobResult{error: &1})
  end

  @impl true
  def grep(%__MODULE__{} = backend, pattern, opts) do
    with_files(backend, opts, &State.grep(State.new(), pattern, &1), &%Filesystem.GrepResult{error: &1})
  end

  @impl true
  def upload_files(%__MODULE__{} = backend, files, opts) do
    store = store(backend, opts)
    namespace = namespace(backend, opts)

    Enum.map(files, fn {path, content} ->
      with {:ok, path} <- Filesystem.Path.clean_path(path),
           :ok <- put_file(store, namespace, path, FileDataUtils.file_data_from_upload(content)) do
        %Filesystem.UploadResult{path: path}
      else
        {:error, error} -> %Filesystem.UploadResult{path: path, error: error}
      end
    end)
  end

  @impl true
  def download_files(%__MODULE__{} = backend, paths, opts) do
    case load_files(backend, opts) do
      {:ok, files} -> State.download_files(State.new(), paths, state_opts(files, opts))
      {:error, error} -> Enum.map(paths, &%Filesystem.DownloadResult{path: &1, error: error})
    end
  end

  # Runs `fun` with the namespace's files as a `State` backend's options, or
  # builds an error result when they can't be loaded.
  defp with_files(backend, opts, fun, error_result) do
    case load_files(backend, opts) do
      {:ok, files} -> fun.(state_opts(files, opts))
      {:error, error} -> error_result.(error)
    end
  end

  # The paths here are relative to the namespace, whatever route prefix an
  # enclosing composite passed.
  defp state_opts(files, opts) do
    opts
    |> Keyword.delete(:route_prefix)
    |> Keyword.put(:state, %{files: files})
  end

  defp load_files(%__MODULE__{} = backend, opts) do
    namespace = namespace(backend, opts)

    case store(backend, opts) do
      nil ->
        {:error, @missing_store}

      store ->
        case Memory.search(store, namespace, limit: 100_000) do
          # Search matches namespace prefixes; files of nested namespaces
          # belong to other backends.
          items when is_list(items) ->
            {:ok, for(item <- items, item.namespace == namespace, into: %{}, do: {"/" <> item.key, item.value})}

          {:error, error} ->
            {:error, error_message(error)}
        end
    end
  end

  # Saves the one file a successful write or edit changed.
  defp persist(%{error: nil, path: path, files_update: files} = result, backend, opts) do
    case put_file(store(backend, opts), namespace(backend, opts), path, Map.fetch!(files, path)) do
      :ok -> %{result | files_update: nil}
      {:error, error} -> %{result | files_update: nil, error: error}
    end
  end

  defp persist(result, _backend, _opts), do: %{result | files_update: nil}

  defp put_file(nil, _namespace, _path, _data), do: {:error, @missing_store}

  defp put_file(store, namespace, path, data) do
    case Memory.put(store, namespace, String.trim_leading(path, "/"), stored_value(data)) do
      {:ok, _item} -> :ok
      {:error, error} -> {:error, error_message(error)}
    end
  end

  defp stored_value(data) do
    %FileData{} = data = FileDataUtils.normalize_file_data(data)

    %{
      "content" => data.content,
      "encoding" => data.encoding,
      "created_at" => data.created_at,
      "modified_at" => data.modified_at
    }
  end

  defp error_message(%Error{message: message}), do: message
  defp error_message(error) when is_binary(error), do: error
  defp error_message(error), do: inspect(error)

  defp store(%__MODULE__{store: store}, opts), do: store || Keyword.get(opts, :store)

  defp namespace(%__MODULE__{namespace: fun}, opts) when is_function(fun, 1) do
    opts
    |> Keyword.get(:runtime)
    |> fun.()
    |> normalize_namespace()
  end

  defp namespace(%__MODULE__{namespace: namespace}, _opts), do: namespace

  defp normalize_namespace_or_factory(namespace) when is_function(namespace, 1), do: namespace
  defp normalize_namespace_or_factory(namespace), do: normalize_namespace(namespace)

  defp normalize_namespace(namespace) do
    namespace = namespace |> List.wrap() |> Enum.map(&to_string/1)

    if Enum.any?(namespace, &(String.contains?(&1, ["*", "?"]) or &1 == "")) do
      raise ArgumentError, "store backend namespace cannot contain empty components or wildcards"
    end

    namespace
  end
end
