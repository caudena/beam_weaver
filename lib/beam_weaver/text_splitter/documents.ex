defmodule BeamWeaver.TextSplitter.Documents do
  @moduledoc false

  alias BeamWeaver.Core.Document
  alias BeamWeaver.Core.Error
  alias BeamWeaver.TextSplitter.Shared
  alias BeamWeaver.Transport
  alias BeamWeaver.Transport.URLPolicy

  # `split_url/3` follows redirects unless the caller's policy says otherwise;
  # every hop must pass the same policy.
  @url_policy_defaults [follow_redirects?: true]

  @spec stream_text(term(), String.t() | Enumerable.t()) ::
          {:ok, Enumerable.t()} | {:error, Error.t()}
  def stream_text(splitter, texts) do
    with :ok <- validate(splitter) do
      {:ok,
       texts
       |> text_stream()
       |> Stream.flat_map(fn
         text when is_binary(text) -> BeamWeaver.TextSplitter.split_text(splitter, text)
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
          case Document.from(value) do
            {:ok, document} -> splitter |> split_document(document) |> with_chunk_ids(document)
            {:error, error} -> raise ArgumentError, error.message
          end
        end)

      {:ok, stream}
    end
  rescue
    exception -> {:error, Error.new(:text_splitter_error, Exception.message(exception))}
  end

  @spec split_file(term(), Path.t(), keyword()) :: {:ok, Enumerable.t()} | {:error, Error.t()}
  def split_file(splitter, path, opts) do
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
  def split_url(splitter, url, opts) do
    policy = url_policy(Keyword.get(opts, :url_policy))

    # The checks that need no DNS run first, so a refused URL never reaches a
    # fetcher.
    with {:ok, _url} <- URLPolicy.validate(url, %{policy | resolve?: false}),
         {:ok, content} <- fetch_url(url, policy, Keyword.get(opts, :fetcher)) do
      metadata =
        opts
        |> Keyword.get(:metadata, %{})
        |> Map.put_new(:source, url)

      split_documents(splitter, [Document.new!(content, metadata: metadata)])
    end
  end

  def create_documents(splitter, texts, opts) do
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

  defp split_document(%BeamWeaver.TextSplitter{} = splitter, document), do: Shared.split_document(splitter, document)
  defp split_document(%module{} = splitter, document), do: module.split_document(splitter, document)

  # The chunks of a document with an id get ids derived from it ("refunds:0",
  # "refunds:1", ...), so storing them keeps every chunk, and the document's id
  # as "parent_id", so indexing can tell which chunks a document no longer has.
  # A chunk split again keeps the parent id it already has.
  defp with_chunk_ids(chunks, %Document{id: nil}), do: chunks

  defp with_chunk_ids(chunks, %Document{id: id}) do
    chunks
    |> Enum.with_index()
    |> Enum.map(fn {chunk, index} ->
      %{chunk | id: "#{id}:#{index}", metadata: Map.put_new(chunk.metadata, "parent_id", id)}
    end)
  end

  defp text_stream(text) when is_binary(text), do: [text]
  defp text_stream(texts), do: texts

  def metadata_for_index(metadata, index) when is_list(metadata), do: Enum.at(metadata, index, %{})
  def metadata_for_index(metadata, _index), do: metadata

  defp url_policy(nil), do: url_policy([])

  defp url_policy(opts) when is_list(opts),
    do: @url_policy_defaults |> Keyword.merge(opts) |> URLPolicy.new() |> pin()

  defp url_policy(%URLPolicy{} = policy), do: pin(policy)

  defp url_policy(other) do
    raise ArgumentError, "expected :url_policy to be a keyword list or a URLPolicy, got: #{inspect(other)}"
  end

  # Resolve the host and connect to the address that passed the check, so a
  # name can't resolve to a public address for the check and a private one
  # for the request.
  defp pin(policy), do: %{policy | resolve?: true, pin_resolved?: true}

  defp fetch_url(url, policy, nil) do
    request = Transport.Request.new(method: :get, url: url)

    case Transport.Safe.request(request, url_policy: policy) do
      {:ok, %Transport.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %Transport.Response{status: status}} ->
        {:error, Error.new(:text_splitter_error, "failed to fetch split URL", %{url: url, status: status})}

      # For a refused redirect, `details.url` is the redirect's target.
      {:error, %Transport.Error{} = error} ->
        {:error, Error.new(error.type, error.message, Map.put_new(error.details, :url, url))}
    end
  end

  defp fetch_url(url, _policy, fetcher) when is_function(fetcher, 1) do
    case fetcher.(url) do
      {:ok, content} when is_binary(content) ->
        {:ok, content}

      {:error, %Error{} = error} ->
        {:error, error}

      other ->
        {:error,
         Error.new(:text_splitter_error, "failed to fetch split URL", %{
           url: url,
           reason: inspect(other)
         })}
    end
  end
end
