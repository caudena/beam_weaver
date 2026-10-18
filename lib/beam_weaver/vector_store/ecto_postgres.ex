defmodule BeamWeaver.VectorStore.EctoPostgres do
  @moduledoc """
  SQL-boundary Postgres/pgvector vector store adapter.

  The adapter deliberately avoids Ecto schemas. Callers provide a Repo and a
  query module compatible with `Ecto.Adapters.SQL.query/3`, which keeps the SQL
  boundary explicit for applications that wrap or instrument database calls.
  """

  @behaviour BeamWeaver.VectorStore

  alias BeamWeaver.VectorStore
  alias BeamWeaver.Adapter.Error, as: AdapterError
  alias BeamWeaver.Core.Document
  alias BeamWeaver.Core.EmbeddingModel
  alias BeamWeaver.Migrations.Postgres.Util
  alias BeamWeaver.Result
  alias BeamWeaver.VectorStore.Filter
  alias BeamWeaver.VectorStore.Scoring

  defstruct repo: nil,
            query_module: Ecto.Adapters.SQL,
            table: "beam_weaver_vectors",
            prefix: nil,
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
      prefix: Keyword.get(opts, :prefix),
      namespace: Keyword.get(opts, :namespace, :default),
      embedding: Keyword.fetch!(opts, :embedding),
      dimensions: Keyword.get(opts, :dimensions, 1_536),
      distance: Util.normalize_distance(Keyword.get(opts, :distance, :cosine)),
      index: Keyword.get(opts, :index, :ivfflat),
      index_opts: Keyword.get(opts, :index_opts, [])
    }
  end

  @impl true
  def add_documents(%__MODULE__{} = store, documents, opts) do
    with :ok <- VectorStore.validate_documents(documents),
         {:ok, vectors} <- VectorStore.embed_documents(store.embedding, documents, opts) do
      explicit_ids = Keyword.get(opts, :ids, [])

      sql = """
      INSERT INTO #{table(store)}
        (id, namespace, content, metadata, embedding, created_at, updated_at)
      VALUES ($1, $2, $3, $4, ($5::text)::vector, now(), now())
      ON CONFLICT (namespace, id)
      DO UPDATE SET content = EXCLUDED.content,
                    metadata = EXCLUDED.metadata,
                    embedding = EXCLUDED.embedding,
                    updated_at = now()
      """

      documents
      |> Enum.zip(vectors)
      |> Enum.with_index()
      |> Result.traverse(fn {{document, vector}, index} ->
        id = VectorStore.id_for(document, explicit_ids, index)
        params = [id, namespace(store), document.content, document.metadata, encode_vector(vector)]
        with {:ok, _result} <- query(store, sql, params), do: {:ok, id}
      end)
    end
  end

  @impl true
  def delete(%__MODULE__{} = store, ids, _opts) do
    sql = "DELETE FROM #{table(store)} WHERE namespace = $1 AND id = ANY($2)"

    with {:ok, _result} <- query(store, sql, [namespace(store), ids]), do: :ok
  end

  def get_by_ids(%__MODULE__{} = store, ids, _opts) do
    sql = """
    SELECT id, content, metadata, embedding::text, 0 AS score
    FROM #{table(store)}
    WHERE namespace = $1 AND id = ANY($2)
    ORDER BY array_position($2, id)
    """

    with {:ok, result} <- query(store, sql, [namespace(store), ids]),
         do: {:ok, result |> rows_from_result() |> Enum.map(&document_from_row/1) |> order_documents(ids)}
  end

  @impl true
  def similarity_search(%__MODULE__{} = store, query, opts),
    do: store |> similarity_search_with_score(query, opts) |> VectorStore.drop_scores()

  @impl true
  def similarity_search_with_score(%__MODULE__{} = store, query, opts) do
    with {:ok, vector} <- EmbeddingModel.embed_query(store.embedding, query, opts) do
      search_by_vector_with_score(store, vector, opts)
    end
  end

  @impl true
  def similarity_search_by_vector(%__MODULE__{} = store, vector, opts),
    do: store |> search_by_vector_with_score(vector, opts) |> VectorStore.drop_scores()

  @impl true
  def max_marginal_relevance_search(%__MODULE__{} = store, query, opts) do
    k = Keyword.get(opts, :k, 4)
    fetch_k = Keyword.get(opts, :fetch_k, max(k * 4, k))
    lambda = Keyword.get(opts, :lambda, Keyword.get(opts, :mmr_lambda, 0.5))

    with {:ok, query_vector} <- EmbeddingModel.embed_query(store.embedding, query, opts),
         {:ok, rows} <- search_rows(store, query_vector, Keyword.put(opts, :k, fetch_k)) do
      candidates = Enum.map(rows, &{document_from_row(&1), decode_vector(&1["embedding"]), row_score(&1)})
      {:ok, candidates |> Scoring.mmr(k, lambda) |> Enum.map(&elem(&1, 0))}
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
      where = ["namespace = $1", filter_sql] |> Enum.reject(&(&1 in ["", "TRUE"])) |> Enum.join(" AND ")

      sql = """
      SELECT id, content, metadata, embedding::text, #{score_sql(store, "$2")} AS score
      FROM #{table(store)}
      WHERE #{where}
      ORDER BY embedding #{distance_operator(store)} ($2::text)::vector
      LIMIT #{max(k, 0)}
      """

      with {:ok, result} <- query(store, sql, [namespace(store), encode_vector(vector)] ++ filter_params),
           do: {:ok, rows_from_result(result)}
    end
  end

  defp order_documents(documents, ids) do
    by_id = Map.new(documents, &{&1.id, &1})
    for id <- ids, document = by_id[to_string(id)], do: document
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

  # The table, in the Postgres schema `prefix:` names, quoted as the migration quotes it.
  defp table(%__MODULE__{} = store), do: Util.qualify(store.prefix, store.table)

  defp query(%__MODULE__{} = store, sql, params),
    do: AdapterError.query(store, sql, params, :vector_store_error, "vector store adapter error")

  defp rows_from_result(%{columns: columns, rows: rows}), do: Enum.map(rows, &(columns |> Enum.zip(&1) |> Map.new()))

  defp document_from_row(row),
    do: Document.new!(row["content"] || "", id: row["id"], metadata: row["metadata"] || %{})

  defp row_score(row), do: row["score"] || 0

  defp encode_vector(vector) when is_list(vector) do
    "[" <> Enum.map_join(vector, ",", &to_string/1) <> "]"
  end

  defp decode_vector(vector) when is_binary(vector) do
    vector
    |> String.trim()
    |> String.trim_leading("[")
    |> String.trim_trailing("]")
    |> String.split(",", trim: true)
    |> Enum.map(&parse_number/1)
  end

  defp parse_number(value) do
    case Float.parse(String.trim(value)) do
      {number, _rest} -> number
      :error -> 0.0
    end
  end

  defp namespace(store), do: to_string(store.namespace)
end
