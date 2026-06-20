defmodule BeamWeaver.BlobParser do
  @moduledoc """
  Behaviour and facade for turning blobs into documents.
  """

  alias BeamWeaver.Blob
  alias BeamWeaver.BlobLike
  alias BeamWeaver.Core.Document
  alias BeamWeaver.Core.Error

  @callback parse(term(), Blob.t(), keyword()) :: {:ok, Enumerable.t()} | {:error, Error.t()}

  @spec parse(term(), term(), keyword()) :: {:ok, Enumerable.t()} | {:error, Error.t()}
  def parse(parser, blob_like, opts \\ []) do
    with {:ok, blob} <- BlobLike.to_blob(blob_like) do
      parser.__struct__.parse(parser, blob, opts)
    end
  rescue
    exception -> {:error, Error.new(:blob_parser_error, Exception.message(exception))}
  end

  def lazy_parse(parser, blob_like, opts \\ []), do: parse(parser, blob_like, opts)

  def parse_all(parser, blob_like, opts \\ []) do
    with {:ok, documents} <- lazy_parse(parser, blob_like, opts) do
      {:ok, Enum.to_list(documents)}
    end
  rescue
    exception -> {:error, Error.new(:blob_parser_error, Exception.message(exception))}
  end

  def text(opts \\ []), do: struct(BeamWeaver.BlobParser.Text, opts: opts)
  def json(opts \\ []), do: struct(BeamWeaver.BlobParser.JSON, opts: opts)
  def json_lines(opts \\ []), do: struct(BeamWeaver.BlobParser.JSONLines, opts: opts)

  def csv(opts \\ []),
    do: struct(BeamWeaver.BlobParser.CSV, opts: Keyword.put_new(opts, :separator, ","))

  def tsv(opts \\ []),
    do: struct(BeamWeaver.BlobParser.CSV, opts: Keyword.put(opts, :separator, "\t"))

  def html_text(opts \\ []), do: struct(BeamWeaver.BlobParser.HTMLText, opts: opts)

  defmodule Text do
    @moduledoc false
    @behaviour BeamWeaver.BlobParser

    alias BeamWeaver.Blob
    alias BeamWeaver.Core.Document

    defstruct opts: []

    @impl true
    def parse(%__MODULE__{}, %Blob{} = blob, _opts) do
      with {:ok, data} <- Blob.read(blob) do
        {:ok, [Document.new!(data, metadata: blob.metadata)]}
      end
    end
  end

  defmodule JSON do
    @moduledoc false
    @behaviour BeamWeaver.BlobParser

    alias BeamWeaver.Blob
    alias BeamWeaver.Core.Document
    alias BeamWeaver.Core.Error

    defstruct opts: []

    @impl true
    def parse(%__MODULE__{} = parser, %Blob{} = blob, _opts) do
      with {:ok, data} <- Blob.read(blob),
           {:ok, decoded} <- BeamWeaver.JSON.decode(data) do
        content_key = Keyword.get(parser.opts, :content_key, "content")
        metadata_key = Keyword.get(parser.opts, :metadata_key, "metadata")

        documents =
          decoded |> List.wrap() |> Enum.map(&document(&1, blob, content_key, metadata_key))

        {:ok, documents}
      else
        {:error, %BeamWeaver.JSON.DecodeError{} = error} ->
          {:error, Error.new(:blob_parse_error, "invalid JSON blob", %{reason: Exception.message(error)})}

        {:error, error} ->
          {:error, error}
      end
    end

    def document(%{} = item, blob, content_key, metadata_key) do
      content = fetch_field(item, content_key) || inspect(item)
      metadata = fetch_field(item, metadata_key) || %{}
      Document.new!(to_string(content), metadata: Map.merge(blob.metadata, metadata))
    rescue
      ArgumentError -> Document.new!(inspect(item), metadata: blob.metadata)
    end

    def document(item, blob, _content_key, _metadata_key) do
      Document.new!(to_string(item), metadata: blob.metadata)
    end

    defp fetch_field(map, key) when is_atom(key),
      do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

    defp fetch_field(map, key) when is_binary(key) do
      if Map.has_key?(map, key) do
        Map.fetch!(map, key)
      else
        map
        |> Map.keys()
        |> Enum.find(&(to_string(&1) == key))
        |> case do
          nil -> nil
          existing_key -> Map.fetch!(map, existing_key)
        end
      end
    end

    defp fetch_field(_map, _key), do: nil
  end

  defmodule JSONLines do
    @moduledoc false
    @behaviour BeamWeaver.BlobParser

    alias BeamWeaver.Blob
    alias BeamWeaver.Core.Document
    alias BeamWeaver.Core.Error

    defstruct opts: []

    @impl true
    def parse(%__MODULE__{} = parser, %Blob{} = blob, _opts) do
      with {:ok, data} <- Blob.read(blob) do
        content_key = Keyword.get(parser.opts, :content_key, "content")
        metadata_key = Keyword.get(parser.opts, :metadata_key, "metadata")

        data
        |> String.split(~r/\R/, trim: true)
        |> Enum.reduce_while({:ok, []}, fn line, {:ok, acc} ->
          case BeamWeaver.JSON.decode(line) do
            {:ok, decoded} ->
              doc = BeamWeaver.BlobParser.JSON.document(decoded, blob, content_key, metadata_key)
              {:cont, {:ok, [doc | acc]}}

            {:error, error} ->
              {:halt,
               {:error,
                Error.new(:blob_parse_error, "invalid JSON-lines blob", %{
                  reason: Exception.message(error)
                })}}
          end
        end)
        |> case do
          {:ok, docs} -> {:ok, Enum.reverse(docs)}
          other -> other
        end
      end
    end
  end

  defmodule CSV do
    @moduledoc false
    @behaviour BeamWeaver.BlobParser

    alias BeamWeaver.Blob
    alias BeamWeaver.Core.Document

    defstruct opts: []

    @impl true
    def parse(%__MODULE__{} = parser, %Blob{} = blob, _opts) do
      with {:ok, data} <- Blob.read(blob) do
        rows = BeamWeaver.OutputParser.parse_csv(data, Keyword.get(parser.opts, :separator, ","))
        headers = Keyword.get(parser.opts, :headers, true)
        content_key = Keyword.get(parser.opts, :content_key)
        metadata_keys = Keyword.get(parser.opts, :metadata_keys)

        documents =
          rows
          |> rows_to_maps(headers)
          |> Enum.with_index()
          |> Enum.map(fn {row, index} ->
            row_metadata = metadata(row, metadata_keys, index)
            content = content(row, content_key)

            Document.new!(content,
              metadata:
                blob.metadata
                |> Map.merge(row_metadata)
                |> Map.put_new(:row, index)
            )
          end)

        {:ok, documents}
      end
    end

    defp rows_to_maps([], _headers), do: []

    defp rows_to_maps([header | rows], true) do
      keys = Enum.map(header, &String.trim/1)

      Enum.map(rows, fn row ->
        keys
        |> Enum.zip(row)
        |> Map.new()
      end)
    end

    defp rows_to_maps(rows, headers) when is_list(headers) do
      keys = Enum.map(headers, &to_string/1)

      Enum.map(rows, fn row ->
        keys
        |> Enum.zip(row)
        |> Map.new()
      end)
    end

    defp rows_to_maps(rows, _headers) do
      Enum.map(rows, fn row -> %{"row" => row} end)
    end

    defp content(row, nil), do: BeamWeaver.JSON.encode!(row)

    defp content(row, key) do
      value = Map.get(row, to_string(key)) || Map.get(row, key)
      if is_nil(value), do: BeamWeaver.JSON.encode!(row), else: to_string(value)
    end

    defp metadata(row, nil, _index) do
      row
      |> Enum.reject(fn {_key, value} -> is_list(value) end)
      |> Map.new()
    end

    defp metadata(_row, [], _index), do: %{}

    defp metadata(row, keys, _index) when is_list(keys) do
      keys
      |> Enum.map(&to_string/1)
      |> Enum.reduce(%{}, fn key, acc ->
        if Map.has_key?(row, key), do: Map.put(acc, key, Map.fetch!(row, key)), else: acc
      end)
    end
  end

  defmodule HTMLText do
    @moduledoc false
    @behaviour BeamWeaver.BlobParser

    alias BeamWeaver.Blob
    alias BeamWeaver.Core.Document

    defstruct opts: []

    @impl true
    def parse(%__MODULE__{}, %Blob{} = blob, _opts) do
      with {:ok, data} <- Blob.read(blob) do
        text =
          data
          |> String.replace(~r/<script[\s\S]*?<\/script>/i, " ")
          |> String.replace(~r/<style[\s\S]*?<\/style>/i, " ")
          |> String.replace(~r/<[^>]+>/, " ")
          |> html_entities()
          |> String.replace(~r/\s+/, " ")
          |> String.trim()

        {:ok, [Document.new!(text, metadata: blob.metadata)]}
      end
    end

    defp html_entities(text) do
      text
      |> String.replace("&amp;", "&")
      |> String.replace("&lt;", "<")
      |> String.replace("&gt;", ">")
      |> String.replace("&quot;", "\"")
      |> String.replace("&#39;", "'")
    end
  end
end
