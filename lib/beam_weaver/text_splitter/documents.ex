defmodule BeamWeaver.TextSplitter.Documents do
  @moduledoc false

  alias BeamWeaver.Core.Document
  alias BeamWeaver.Core.Error
  alias BeamWeaver.DocumentLike
  alias BeamWeaver.TextSplitter.Shared

  @spec stream_text(term(), String.t() | Enumerable.t()) ::
          {:ok, Enumerable.t()} | {:error, Error.t()}
  def stream_text(splitter, texts) do
    with :ok <- validate(splitter) do
      {:ok,
       texts
       |> text_stream()
       |> Stream.flat_map(fn
         text when is_binary(text) -> split_text(splitter, text)
         value -> raise ArgumentError, "expected text, got: #{inspect(value)}"
       end)}
    end
  rescue
    exception -> {:error, Error.new(:text_splitter_error, Exception.message(exception))}
  end

  def split_documents(splitter, documents) do
    with :ok <- validate(splitter) do
      stream =
        Stream.flat_map(documents, fn value ->
          case DocumentLike.to_document(value) do
            {:ok, document} -> split_document(splitter, document)
            {:error, error} -> raise ArgumentError, error.message
          end
        end)

      {:ok, stream}
    end
  rescue
    exception -> {:error, Error.new(:text_splitter_error, Exception.message(exception))}
  end

  def transform_documents(splitter, documents, _opts \\ []),
    do: split_documents(splitter, documents)

  @spec split_file(term(), Path.t(), keyword()) :: {:ok, Enumerable.t()} | {:error, Error.t()}
  def split_file(splitter, path, opts \\ []) do
    case File.read(path) do
      {:ok, content} ->
        metadata =
          opts
          |> Keyword.get(:metadata, %{})
          |> Map.put_new(:source, path)

        split_documents(splitter, [Document.new!(content, metadata: metadata)])

      {:error, reason} ->
        {:error,
         Error.new(:text_splitter_error, "failed to read split file", %{
           path: path,
           reason: reason
         })}
    end
  end

  @spec split_url(term(), String.t(), keyword()) :: {:ok, Enumerable.t()} | {:error, Error.t()}
  def split_url(splitter, url, opts \\ []) do
    fetcher = Keyword.get(opts, :fetcher, &default_url_fetcher/1)

    case fetcher.(url) do
      {:ok, content} ->
        metadata =
          opts
          |> Keyword.get(:metadata, %{})
          |> Map.put_new(:source, url)

        split_documents(splitter, [Document.new!(content, metadata: metadata)])

      {:error, %Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error,
         Error.new(:text_splitter_error, "failed to fetch split URL", %{
           url: url,
           reason: inspect(reason)
         })}
    end
  end

  def create_documents(splitter, texts, opts \\ []) do
    metadata = Keyword.get(opts, :metadata, %{})

    texts
    |> Stream.with_index()
    |> Stream.map(fn
      {%Document{} = document, _index} ->
        document

      {text, index} when is_binary(text) ->
        Document.new!(text, metadata: metadata_for_index(metadata, index))

      {value, _index} ->
        raise ArgumentError, "expected text or document, got: #{inspect(value)}"
    end)
    |> then(&split_documents(splitter, &1))
  end

  def validate(%{__struct__: BeamWeaver.TextSplitter} = splitter), do: Shared.validate(splitter)
  def validate(%{__struct__: BeamWeaver.TextSplitter.MarkdownHeaders}), do: :ok
  def validate(%{__struct__: BeamWeaver.TextSplitter.HTMLHeaders}), do: :ok

  def validate(%module{} = splitter) do
    if function_exported?(module, :split_document, 2),
      do: Shared.validate(splitter),
      else: {:error, Error.new(:invalid_text_splitter, "expected a BeamWeaver text splitter")}
  end

  def validate(_splitter),
    do: {:error, Error.new(:invalid_text_splitter, "expected a BeamWeaver text splitter")}

  defp split_document(%{__struct__: BeamWeaver.TextSplitter} = splitter, %Document{} = document),
    do: Shared.split_document(splitter, document)

  defp split_document(%module{} = splitter, %Document{} = document) do
    if function_exported?(module, :split_document, 2),
      do: module.split_document(splitter, document),
      else: raise(ArgumentError, "expected a BeamWeaver text splitter")
  end

  defp split_text(%{__struct__: BeamWeaver.TextSplitter} = splitter, text),
    do: Shared.split_text(splitter, text)

  defp split_text(%module{} = splitter, text), do: module.split_text(splitter, text)

  defp text_stream(text) when is_binary(text), do: [text]
  defp text_stream(texts), do: texts

  defp metadata_for_index(metadata, index) when is_list(metadata),
    do: Enum.at(metadata, index, %{})

  defp metadata_for_index(metadata, _index), do: metadata

  defp default_url_fetcher(url) do
    :inets.start()
    :ssl.start()

    request = {String.to_charlist(url), []}

    case :httpc.request(:get, request, [], body_format: :binary) do
      {:ok, {{_http, status, _reason}, _headers, body}} when status in 200..299 ->
        {:ok, body}

      {:ok, {{_http, status, reason}, _headers, _body}} ->
        {:error, {status, to_string(reason)}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
