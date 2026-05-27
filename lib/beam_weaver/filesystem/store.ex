defmodule BeamWeaver.Filesystem.Store do
  @moduledoc "Backend that stores files in a BeamWeaver long-term memory store."

  use BeamWeaver.Filesystem

  alias BeamWeaver.Filesystem
  alias BeamWeaver.Filesystem.State
  alias BeamWeaver.Memory

  defstruct namespace: ["deepagents", "files"], store: nil

  def new(opts \\ []) do
    %__MODULE__{
      namespace: normalize_namespace_or_factory(Keyword.get(opts, :namespace, ["deepagents", "files"])),
      store: Keyword.get(opts, :store)
    }
  end

  @impl true
  def ls(%__MODULE__{} = backend, path, opts),
    do: state_backend(backend, opts) |> State.ls(path, state_opts(backend, opts))

  @impl true
  def read(%__MODULE__{} = backend, path, opts),
    do: state_backend(backend, opts) |> State.read(path, state_opts(backend, opts))

  @impl true
  def write(%__MODULE__{} = backend, path, content, opts) do
    result = state_backend(backend, opts) |> State.write(path, content, state_opts(backend, opts))
    persist_update(backend, result.files_update, opts)
    %{result | files_update: nil}
  end

  @impl true
  def edit(%__MODULE__{} = backend, path, old, new, opts) do
    result = state_backend(backend, opts) |> State.edit(path, old, new, state_opts(backend, opts))
    persist_update(backend, result.files_update, opts)
    %{result | files_update: nil}
  end

  @impl true
  def glob(%__MODULE__{} = backend, pattern, opts),
    do: state_backend(backend, opts) |> State.glob(pattern, state_opts(backend, opts))

  @impl true
  def grep(%__MODULE__{} = backend, pattern, opts),
    do: state_backend(backend, opts) |> State.grep(pattern, state_opts(backend, opts))

  @impl true
  def upload_files(%__MODULE__{} = backend, files, opts) do
    store = backend.store || Keyword.get(opts, :store)
    namespace = namespace(backend, opts)

    Enum.map(files, fn {path, content} ->
      with {:ok, path} <- BeamWeaver.Filesystem.Utils.clean_path(path),
           true <- not is_nil(store) do
        data = BeamWeaver.Filesystem.Utils.file_data_from_upload(content)
        Memory.put(store, namespace, String.trim_leading(path, "/"), data)
        %Filesystem.UploadResult{path: path}
      else
        false -> %Filesystem.UploadResult{path: path, error: "missing_store"}
        {:error, error} -> %Filesystem.UploadResult{path: path, error: error}
      end
    end)
  end

  @impl true
  def download_files(%__MODULE__{} = backend, paths, opts) do
    state_backend(backend, opts) |> State.download_files(paths, state_opts(backend, opts))
  end

  defp state_backend(_backend, _opts), do: State.new()

  defp state_opts(backend, opts),
    do: Keyword.put(opts, :state, %{files: load_files(backend, opts)})

  defp load_files(%__MODULE__{} = backend, opts) do
    store = backend.store || Keyword.get(opts, :store)

    namespace = namespace(backend, opts)

    case store && Memory.search(store, namespace, limit: 100_000) do
      items when is_list(items) -> Map.new(items, &{"/" <> &1.key, &1.value})
      _other -> %{}
    end
  end

  defp persist_update(_backend, nil, _opts), do: :ok

  defp persist_update(%__MODULE__{} = backend, files, opts) when is_map(files) do
    store = backend.store || Keyword.get(opts, :store)
    namespace = namespace(backend, opts)

    if store do
      Enum.each(files, fn {path, data} ->
        key = String.trim_leading(path, "/")
        Memory.put(store, namespace, key, data)
      end)
    end

    :ok
  end

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
