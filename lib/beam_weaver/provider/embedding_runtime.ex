defmodule BeamWeaver.Provider.EmbeddingRuntime do
  @moduledoc false

  alias BeamWeaver.Core.Async
  alias BeamWeaver.Result
  alias BeamWeaver.Tokenizer

  @doc false
  def embed_documents(model, documents, opts, embed_fun, error_opts) when is_list(documents) do
    chunk_size = Keyword.get(opts, :chunk_size, Map.get(model, :chunk_size))

    documents =
      maybe_skip_empty(documents, Keyword.get(opts, :skip_empty, Map.get(model, :skip_empty)))

    if check_embedding_ctx_length?(model, opts) do
      embed_documents_by_token_budget(model, documents, chunk_size, opts, embed_fun, error_opts)
    else
      embed_document_batches(documents, chunk_size, opts, embed_fun)
    end
  end

  @doc false
  def async_embed_documents(model, documents, opts, embed_documents_fun) do
    Async.run_call(opts, &embed_documents_fun.(model, documents, &1))
  end

  @doc false
  def embed_query(_model, query, opts, embed_fun, error_opts) when is_binary(query) do
    case embed_fun.(query, opts) do
      {:ok, [vector]} ->
        {:ok, vector}

      {:ok, vectors} ->
        {:error,
         error(
           error_opts,
           :invalid_response,
           "#{provider_name(error_opts)} returned an unexpected query embedding count",
           %{
             count: length(vectors)
           }
         )}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc false
  def async_embed_query(model, query, opts, embed_query_fun) do
    Async.run_call(opts, &embed_query_fun.(model, query, &1))
  end

  @doc false
  def async_batch_queries(model, queries, opts, embed_query_fun) when is_list(queries) do
    Async.batch_call(queries, opts, &embed_query_fun.(model, &1, &2))
  end

  @doc false
  def embeddings_from_response(%{"data" => data}, error_opts) when is_list(data) do
    embeddings =
      data
      |> Enum.sort_by(&Map.get(&1, "index", 0))
      |> Enum.map(&Map.get(&1, "embedding"))

    if Enum.all?(embeddings, &valid_vector?/1) do
      {:ok, embeddings}
    else
      {:error,
       error(
         error_opts,
         :invalid_response,
         "#{provider_name(error_opts)} embedding response contained invalid vectors"
       )}
    end
  end

  def embeddings_from_response(_response, error_opts) do
    {:error,
     error(
       error_opts,
       :invalid_response,
       "#{provider_name(error_opts)} embedding response missing data"
     )}
  end

  defp embed_document_batches(documents, chunk_size, opts, embed_fun) do
    documents
    |> Enum.chunk_every(chunk_size)
    |> Result.flat_traverse(&embed_fun.(&1, opts))
  end

  defp embed_documents_by_token_budget(model, documents, chunk_size, opts, embed_fun, error_opts) do
    with {:ok, tokenizer} <- tokenizer(model, opts, error_opts),
         :ok <- validate_special_tokens(documents, model, opts, error_opts),
         {:ok, records} <- token_chunk_records(documents, tokenizer, model, opts),
         {:ok, vectors} <- embed_token_records(records, chunk_size, opts, embed_fun) do
      {:ok, aggregate_token_records(records, vectors, length(documents))}
    end
  end

  defp tokenizer(model, opts, error_opts) do
    case Keyword.get(opts, :tokenizer, Map.get(model, :tokenizer)) do
      nil ->
        {:error, error(error_opts, :invalid_tokenizer, "token-aware embeddings require a tokenizer")}

      tokenizer ->
        {:ok, tokenizer}
    end
  end

  defp token_chunk_records(documents, tokenizer, model, opts) do
    ctx_length =
      max(Keyword.get(opts, :embedding_ctx_length, Map.get(model, :embedding_ctx_length)), 1)

    tokenizer_opts = tokenizer_opts(model, opts)

    documents
    |> Enum.with_index()
    |> Result.flat_traverse(fn {document, index} ->
      case Tokenizer.split_tokens(tokenizer, document, tokenizer_opts) do
        {:ok, []} ->
          {:ok, []}

        {:ok, tokens} ->
          {:ok,
           Enum.map(Enum.chunk_every(tokens, ctx_length), fn chunk_tokens ->
             %{
               document_index: index,
               input: Enum.join(chunk_tokens),
               weight: max(length(chunk_tokens), 1)
             }
           end)}

        {:error, error} ->
          {:error, error}
      end
    end)
  end

  defp embed_token_records([], _chunk_size, _opts, _embed_fun), do: {:ok, []}

  defp embed_token_records(records, chunk_size, opts, embed_fun) do
    records
    |> Enum.chunk_every(chunk_size)
    |> Result.flat_traverse(fn batch ->
      inputs = Enum.map(batch, & &1.input)
      embed_fun.(inputs, opts)
    end)
  end

  defp aggregate_token_records(records, vectors, document_count) do
    if document_count == 0 do
      []
    else
      do_aggregate_token_records(records, vectors, document_count)
    end
  end

  defp do_aggregate_token_records(records, vectors, document_count) do
    grouped =
      records
      |> Enum.zip(vectors)
      |> Enum.group_by(fn {record, _vector} -> record.document_index end)

    Enum.map(0..(document_count - 1)//1, fn index ->
      grouped
      |> Map.get(index, [])
      |> weighted_average_vector()
    end)
  end

  defp weighted_average_vector([]), do: []

  defp weighted_average_vector([{_record, vector}]), do: vector

  defp weighted_average_vector(record_vectors) do
    total_weight =
      Enum.reduce(record_vectors, 0, fn {record, _vector}, acc -> acc + record.weight end)

    dimensions = record_vectors |> hd() |> elem(1) |> length()

    0..(dimensions - 1)//1
    |> Enum.map(fn position ->
      weighted_sum =
        Enum.reduce(record_vectors, 0.0, fn {record, vector}, acc ->
          acc + Enum.at(vector, position, 0.0) * record.weight
        end)

      weighted_sum / max(total_weight, 1)
    end)
    |> normalize_vector()
  end

  defp normalize_vector(vector) do
    norm =
      vector
      |> Enum.reduce(0.0, fn value, acc -> acc + value * value end)
      |> :math.sqrt()

    if norm == 0.0, do: vector, else: Enum.map(vector, &(&1 / norm))
  end

  defp check_embedding_ctx_length?(model, opts),
    do: Keyword.get(opts, :check_embedding_ctx_length, Map.get(model, :check_embedding_ctx_length?))

  defp tokenizer_opts(model, opts) do
    [
      allowed_special: Keyword.get(opts, :allowed_special, Map.get(model, :allowed_special)),
      disallowed_special: Keyword.get(opts, :disallowed_special, Map.get(model, :disallowed_special))
    ]
  end

  defp validate_special_tokens(documents, model, opts, error_opts) do
    allowed =
      opts
      |> Keyword.get(:allowed_special, Map.get(model, :allowed_special))
      |> normalize_special_tokens()

    disallowed =
      opts
      |> Keyword.get(:disallowed_special, Map.get(model, :disallowed_special))
      |> normalize_special_tokens()
      |> Enum.reject(&(&1 in allowed))

    case Enum.find(disallowed, fn token -> Enum.any?(documents, &String.contains?(&1, token)) end) do
      nil ->
        :ok

      token ->
        {:error,
         error(
           error_opts,
           :disallowed_special_token,
           "embedding input contains a disallowed special token",
           %{token: token}
         )}
    end
  end

  defp normalize_special_tokens(nil), do: []
  defp normalize_special_tokens(:all), do: []
  defp normalize_special_tokens("all"), do: []
  defp normalize_special_tokens(tokens), do: List.wrap(tokens) |> Enum.map(&to_string/1)

  defp valid_vector?(vector) when is_list(vector) and vector != [] do
    Enum.all?(vector, &is_number/1)
  end

  defp valid_vector?(_vector), do: false

  defp maybe_skip_empty(documents, true) do
    Enum.reject(documents, fn
      document when is_binary(document) -> String.trim(document) == ""
      _document -> false
    end)
  end

  defp maybe_skip_empty(documents, _skip_empty?), do: documents

  defp error(opts, type, message, details \\ %{}) do
    error_module = Keyword.fetch!(opts, :error_module)
    error_module.new(type, message, details)
  end

  defp provider_name(opts), do: Keyword.fetch!(opts, :provider_name)
end
