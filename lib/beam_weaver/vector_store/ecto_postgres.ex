defmodule BeamWeaver.VectorStore.EctoPostgres do
  @moduledoc """
  SQL-boundary Postgres/pgvector vector store adapter.

  The adapter deliberately avoids Ecto schemas. Callers provide a Repo and a
  query module compatible with `Ecto.Adapters.SQL.query/3`, which keeps the SQL
  boundary explicit for applications that wrap or instrument database calls.
  """

  @behaviour BeamWeaver.VectorStore

  alias BeamWeaver.Adapter.Error, as: AdapterError
  alias BeamWeaver.Core.Document
  alias BeamWeaver.Core.EmbeddingModel
  alias BeamWeaver.Core.Error
  alias BeamWeaver.VectorStore.Filter
  alias BeamWeaver.VectorStore.Scoring

  defstruct repo: nil,
            query_module: Ecto.Adapters.SQL,
            table: "beam_weaver_vectors",
            namespace: :default,
            embedding: nil,
            dimensions: 1_536,
            distance: :cosine,
            index: :ivfflat,
            index_opts: []

  def new(opts) do
    %__MODULE__{
      repo: Keyword.fetch!(opts, :repo),
      query_module: Keyword.get(opts, :query_module, Ecto.Adapters.SQL),
      table: Keyword.get(opts, :table, "beam_weaver_vectors"),
      namespace: Keyword.get(opts, :namespace, :default),
      embedding: Keyword.fetch!(opts, :embedding),
      dimensions: Keyword.get(opts, :dimensions, 1_536),
      distance: normalize_distance(Keyword.get(opts, :distance, :cosine)),
      index: Keyword.get(opts, :index, :ivfflat),
      index_opts: Keyword.get(opts, :index_opts, [])
    }
  end

  @impl true
  def add_documents(%__MODULE__{} = store, documents, opts) do
    with :ok <- validate_documents(documents),
         {:ok, vectors} <- embed_documents(store.embedding, documents, opts) do
      explicit_ids = Keyword.get(opts, :ids, [])

      Enum.reduce_while(Enum.zip(documents, vectors), {:ok, []}, fn {document, vector}, {:ok, ids} ->
        index = length(ids)
        id = id_for(document, explicit_ids, index)

        sql = """
        INSERT INTO #{store.table}
          (id, namespace, content, metadata, embedding, created_at, updated_at)
        VALUES ($1, $2, $3, $4, ($5::text)::vector, now(), now())
        ON CONFLICT (namespace, id)
        DO UPDATE SET content = EXCLUDED.content,
                      metadata = EXCLUDED.metadata,
                      embedding = EXCLUDED.embedding,
                      updated_at = now()
        """

        params = [
          id,
          namespace(store),
          document.content,
          document.metadata,
          encode_vector(vector)
        ]

        case query(store, sql, params) do
          {:ok, _result} -> {:cont, {:ok, [id | ids]}}
          {:error, error} -> {:halt, {:error, normalize_error(error)}}
        end
      end)
      |> case do
        {:ok, ids} -> {:ok, Enum.reverse(ids)}
        other -> other
      end
    end
  end

  @impl true
  def delete(%__MODULE__{} = store, ids, _opts) do
    sql = "DELETE FROM #{store.table} WHERE namespace = $1 AND id = ANY($2)"

    case query(store, sql, [namespace(store), ids]) do
      {:ok, _result} -> :ok
      {:error, error} -> {:error, normalize_error(error)}
    end
  end

  def get_by_ids(%__MODULE__{} = store, ids, _opts) do
    sql = """
    SELECT id, content, metadata, embedding::text, 0 AS score
    FROM #{store.table}
    WHERE namespace = $1 AND id = ANY($2)
    ORDER BY array_position($2, id)
    """

    case query(store, sql, [namespace(store), ids]) do
      {:ok, result} ->
        documents =
          result
          |> rows_from_result()
          |> Enum.map(&document_from_row/1)
          |> order_documents(ids)

        {:ok, documents}

      {:error, error} ->
        {:error, normalize_error(error)}
    end
  end

  @impl true
  def similarity_search(%__MODULE__{} = store, query, opts) do
    with {:ok, scored} <- similarity_search_with_score(store, query, opts) do
      {:ok, Enum.map(scored, &elem(&1, 0))}
    end
  end

  @impl true
  def similarity_search_with_score(%__MODULE__{} = store, query, opts) do
    with {:ok, vector} <- EmbeddingModel.embed_query(store.embedding, query, opts) do
      search_by_vector_with_score(store, vector, opts)
    end
  end

  @impl true
  def similarity_search_by_vector(%__MODULE__{} = store, vector, opts) do
    with {:ok, scored} <- search_by_vector_with_score(store, vector, opts) do
      {:ok, Enum.map(scored, &elem(&1, 0))}
    end
  end

  @impl true
  def max_marginal_relevance_search(%__MODULE__{} = store, query, opts) do
    k = Keyword.get(opts, :k, 4)
    fetch_k = Keyword.get(opts, :fetch_k, max(k * 4, k))
    lambda = Keyword.get(opts, :lambda, Keyword.get(opts, :mmr_lambda, 0.5))

    with {:ok, query_vector} <- EmbeddingModel.embed_query(store.embedding, query, opts),
         {:ok, rows} <- search_rows(store, query_vector, Keyword.put(opts, :k, fetch_k)) do
      candidates =
        rows
        |> Enum.map(fn row ->
          doc = document_from_row(row)
          vector = row_vector(row)
          score = row_score(row)
          {doc, vector, score}
        end)

      selected =
        query_vector
        |> Scoring.mmr(candidates, k, lambda, [])
        |> Enum.map(&elem(&1, 0))

      {:ok, selected}
    end
  end

  defp search_by_vector_with_score(store, vector, opts) do
    with {:ok, rows} <- search_rows(store, vector, opts) do
      {:ok, Enum.map(rows, fn row -> {document_from_row(row), row_score(row)} end)}
    end
  end

  defp search_rows(store, vector, opts) do
    k = Keyword.get(opts, :k, 4)
    filter = Keyword.get(opts, :filter, %{})

    with {:ok, {filter_sql, filter_params}} <- Filter.to_sql(filter, 3) do
      where =
        ["namespace = $1", filter_sql] |> Enum.reject(&(&1 in ["", "TRUE"])) |> Enum.join(" AND ")

      sql = """
      SELECT id, content, metadata, embedding::text, #{score_sql(store, "$2")} AS score
      FROM #{store.table}
      WHERE #{if where == "", do: "TRUE", else: where}
      ORDER BY embedding #{distance_operator(store)} ($2::text)::vector
      LIMIT #{max(k, 0)}
      """

      params = [namespace(store), encode_vector(vector)] ++ filter_params

      case query(store, sql, params) do
        {:ok, result} -> {:ok, rows_from_result(result)}
        {:error, error} -> {:error, normalize_error(error)}
      end
    end
  end

  defp normalize_distance(distance) when distance in [:cosine, "cosine"], do: :cosine
  defp normalize_distance(distance) when distance in [:l2, :euclidean, "l2", "euclidean"], do: :l2

  defp normalize_distance(distance)
       when distance in [:inner_product, :max_inner_product, "inner_product", "max_inner_product"],
       do: :inner_product

  defp normalize_distance(_distance), do: :cosine

  defp id_for(%Document{} = document, explicit_ids, index) do
    explicit_ids
    |> Enum.at(index)
    |> Kernel.||(document.id)
    |> Kernel.||(stable_id(document))
    |> to_string()
  end

  defp order_documents(documents, ids) do
    by_id = Map.new(documents, &{&1.id, &1})

    ids
    |> Enum.map(&to_string/1)
    |> Enum.flat_map(fn id ->
      case by_id do
        %{^id => document} -> [document]
        _other -> []
      end
    end)
  end

  defp distance_operator(%__MODULE__{distance: :l2}), do: "<->"
  defp distance_operator(%__MODULE__{distance: :inner_product}), do: "<#>"
  defp distance_operator(%__MODULE__{}), do: "<=>"

  defp score_sql(%__MODULE__{distance: :l2}, param),
    do: "1 / (1 + (embedding <-> (#{param}::text)::vector))"

  defp score_sql(%__MODULE__{distance: :inner_product}, param),
    do: "-(embedding <#> (#{param}::text)::vector)"

  defp score_sql(%__MODULE__{}, param),
    do: "1 - (embedding <=> (#{param}::text)::vector)"

  defp query(%__MODULE__{} = store, sql, params) do
    AdapterError.query(store, sql, params,
      type: :vector_store_error,
      message: "vector store adapter error"
    )
  end

  defp embed_documents(embedding, documents, opts) do
    documents
    |> Enum.map(& &1.content)
    |> then(&EmbeddingModel.embed_documents(embedding, &1, opts))
  end

  defp validate_documents(documents) do
    if Enum.all?(documents, &match?(%Document{}, &1)),
      do: :ok,
      else: {:error, Error.new(:invalid_documents, "expected BeamWeaver documents")}
  end

  defp rows_from_result(%{columns: columns, rows: rows}) when is_list(columns) do
    Enum.map(rows, fn row -> columns |> Enum.zip(row) |> Map.new() end)
  end

  defp rows_from_result(%{rows: rows}), do: Enum.map(rows, &row_map/1)
  defp rows_from_result(rows) when is_list(rows), do: Enum.map(rows, &row_map/1)
  defp rows_from_result(_result), do: []

  defp row_map(%{} = row), do: row

  defp row_map([id, content, metadata, embedding, score]),
    do: %{
      "id" => id,
      "content" => content,
      "metadata" => metadata,
      "embedding" => embedding,
      "score" => score
    }

  defp row_map(row), do: %{"row" => row}

  defp document_from_row(row) do
    Document.new!(
      fetch_row(row, ["content", :content]) || "",
      id: fetch_row(row, ["id", :id]),
      metadata: fetch_row(row, ["metadata", :metadata]) || %{}
    )
  end

  defp row_score(row), do: fetch_row(row, ["score", :score]) || 0

  defp row_vector(row) do
    row
    |> fetch_row(["embedding", :embedding])
    |> decode_vector()
  end

  defp fetch_row(row, keys) do
    Enum.find_value(keys, fn key ->
      if Map.has_key?(row, key), do: Map.fetch!(row, key), else: nil
    end)
  end

  defp encode_vector(vector) when is_list(vector) do
    "[" <> Enum.map_join(vector, ",", &to_string/1) <> "]"
  end

  defp decode_vector(vector) when is_list(vector), do: vector

  defp decode_vector(vector) when is_binary(vector) do
    vector
    |> String.trim()
    |> String.trim_leading("[")
    |> String.trim_trailing("]")
    |> String.split(",", trim: true)
    |> Enum.map(&parse_number/1)
  rescue
    _exception -> []
  end

  defp decode_vector(_vector), do: []

  defp parse_number(value) do
    case Float.parse(String.trim(value)) do
      {number, _rest} -> number
      :error -> 0.0
    end
  end

  defp stable_id(%Document{} = document) do
    :sha256
    |> :crypto.hash(:erlang.term_to_binary({document.content, document.metadata}))
    |> Base.encode16(case: :lower)
  end

  defp namespace(store), do: to_string(store.namespace)

  defp normalize_error(%Error{} = error), do: error
end
