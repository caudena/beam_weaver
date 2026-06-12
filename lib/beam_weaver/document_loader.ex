defmodule BeamWeaver.DocumentLoader do
  @moduledoc """
  Behaviour and facade for lazy document loading.
  """

  alias BeamWeaver.Blob
  alias BeamWeaver.BlobLoader
  alias BeamWeaver.BlobParser
  alias BeamWeaver.Core.Async
  alias BeamWeaver.Core.Document
  alias BeamWeaver.Core.Error
  alias BeamWeaver.TextSplitter

  @callback load(term(), keyword()) :: {:ok, Enumerable.t()} | {:error, Error.t()}

  def load(loader, opts \\ []) do
    loader.__struct__.load(loader, opts)
  rescue
    exception -> {:error, Error.new(:document_loader_error, Exception.message(exception))}
  end

  def lazy_load(loader, opts \\ []), do: load(loader, opts)

  def load_all(loader, opts \\ []) do
    with {:ok, documents} <- lazy_load(loader, opts) do
      {:ok, Enum.to_list(documents)}
    end
  rescue
    exception -> {:error, Error.new(:document_loader_error, Exception.message(exception))}
  end

  def load_and_split(loader, text_splitter \\ nil, opts \\ []) do
    splitter = text_splitter || TextSplitter.recursive_character()

    with {:ok, documents} <- lazy_load(loader, opts) do
      TextSplitter.split_documents(splitter, documents)
    end
  end

  def async_lazy_load(loader, opts \\ []) do
    Async.run(fn -> lazy_load(loader, opts) end, opts)
  end

  def async_load_all(loader, opts \\ []) do
    Async.run(fn -> load_all(loader, opts) end, opts)
  end

  def text(data, opts \\ []) when is_binary(data) do
    struct(BeamWeaver.DocumentLoader.Text, source: data, opts: opts)
  end

  def paths(paths, opts \\ []) do
    struct(BeamWeaver.DocumentLoader.Path, paths: List.wrap(paths), opts: opts)
  end

  def blobs(blob_loader, blob_parser, opts \\ []) do
    struct(BeamWeaver.DocumentLoader.Blobs,
      blob_loader: blob_loader,
      blob_parser: blob_parser,
      opts: opts
    )
  end

  def urls(urls, opts \\ []) do
    parser = Keyword.get(opts, :parser, BlobParser.text())

    blobs(
      BlobLoader.urls(urls, Keyword.delete(opts, :parser)),
      parser,
      opts
    )
  end

  def url(urls, opts \\ []), do: urls(urls, opts)

  defmodule Text do
    @moduledoc false
    @behaviour BeamWeaver.DocumentLoader

    defstruct [:source, opts: []]

    def load(%__MODULE__{source: text, opts: opts}, _load_opts) do
      {:ok, [Document.new!(text, metadata: Keyword.get(opts, :metadata, %{}))]}
    end
  end

  defmodule Path do
    @moduledoc false
    @behaviour BeamWeaver.DocumentLoader

    defstruct paths: [], opts: []

    def load(%__MODULE__{paths: paths, opts: opts}, _load_opts) do
      stream =
        Stream.map(paths, fn path ->
          with {:ok, blob} <- Blob.from_path(path, opts),
               {:ok, data} <- Blob.read(blob) do
            Document.new!(data, metadata: blob.metadata)
          else
            {:error, error} -> raise RuntimeError, message: error.message
          end
        end)

      {:ok, stream}
    end
  end

  defmodule Blobs do
    @moduledoc false
    @behaviour BeamWeaver.DocumentLoader

    defstruct [:blob_loader, :blob_parser, opts: []]

    @impl true
    def load(%__MODULE__{} = loader, opts) do
      opts = Keyword.merge(loader.opts, opts)

      with {:ok, blobs} <- BlobLoader.load(loader.blob_loader, opts) do
        {:ok,
         Stream.flat_map(blobs, fn blob ->
           case BlobParser.parse(loader.blob_parser, blob, opts) do
             {:ok, docs} -> docs
             {:error, error} -> raise RuntimeError, message: error.message
           end
         end)}
      end
    end
  end
end
