defmodule BeamWeaver.VectorStoreEctoPostgresTest do
  use ExUnit.Case, async: true

  # Upstream references:
  # - langchain standard vectorstore tests for add/delete/search/filter behavior
  # - pgvector adapter behavior translated to an explicit SQL-boundary adapter

  alias BeamWeaver.Core.Async
  alias BeamWeaver.Core.Document
  alias BeamWeaver.Models.FakeEmbeddingModel
  alias BeamWeaver.Retriever
  alias BeamWeaver.VectorStore
  alias BeamWeaver.VectorStore.EctoPostgres
  alias BeamWeaver.VectorStore.ETS
  alias BeamWeaver.VectorStore.Filter

  test "ETS vectorstore supports operator metadata filters" do
    store = ETS.new(embedding: %FakeEmbeddingModel{})

    assert {:ok, _ids} =
             VectorStore.add_documents(store, [
               Document.new!("alpha", metadata: %{group: "a", nested: %{rank: 1}}),
               Document.new!("beta", metadata: %{group: "b", nested: %{rank: 3}})
             ])

    assert {:ok, [%Document{content: "beta"}]} =
             VectorStore.similarity_search(store, "beta",
               k: 4,
               filter: %{"nested.rank" => %{gte: 2}}
             )

    assert {:ok, [%Document{metadata: %{group: "a"}}]} =
             VectorStore.similarity_search(store, "alpha", k: 4, filter: %{group: %{in: ["a"]}})
  end

  test "vectorstore add_texts and async variants delegate through document storage" do
    # Translates langchain_core vectorstores/test_vectorstore.py default add_texts/aadd_texts behavior.
    store = ETS.new(embedding: %FakeEmbeddingModel{})

    assert {:ok, ["3", "4"]} =
             VectorStore.add_texts(store, ["hello", "world"],
               ids: ["3", "4"],
               metadatas: [%{kind: "greeting"}, %{kind: "noun"}]
             )

    assert {:ok,
            [
              %Document{id: "3", content: "hello", metadata: %{kind: "greeting"}},
              %Document{id: "4", content: "world", metadata: %{kind: "noun"}}
            ]} = VectorStore.get_by_ids(store, ["3", "4"])

    task = VectorStore.async_add_texts(store, ["foo", "bar"], ids: ["5", "6"])
    assert {:ok, ["5", "6"]} = Async.await(task)
  end

  test "vectorstore async search, get, MMR, and delete mirror sync facade behavior" do
    # Upstream references:
    # - langchain/libs/core/langchain_core/vectorstores/base.py
    # - langchain/libs/standard-tests/langchain_tests/integration_tests/vectorstores.py
    store = ETS.new(embedding: %FakeEmbeddingModel{})

    assert {:ok, ["a", "b"]} =
             VectorStore.add_texts(store, ["alpha document", "beta document"],
               ids: ["a", "b"],
               metadatas: [%{kind: "a"}, %{kind: "b"}]
             )

    assert {:ok, [%Document{id: "a"}]} =
             VectorStore.async_similarity_search(store, "alpha", k: 1)
             |> Async.await()

    assert {:ok, [{%Document{}, vector_score}]} =
             VectorStore.async_similarity_search_with_score_by_vector(store, [1.0, 1.0, 1.0], k: 1)
             |> Async.await()

    assert is_number(vector_score)

    assert {:ok, [{%Document{id: "a"}, score}]} =
             VectorStore.async_similarity_search_with_score(store, "alpha", k: 1)
             |> Async.await()

    assert is_number(score)

    assert {:ok, [{%Document{id: "a"}, ^score}]} =
             VectorStore.async_similarity_search_with_relevance_scores(store, "alpha",
               k: 1,
               score_threshold: score
             )
             |> Async.await()

    assert {:ok, [%Document{id: "a"}]} =
             VectorStore.async_search(store, "alpha", :similarity_score,
               k: 2,
               score_threshold: score
             )
             |> Async.await()

    assert {:ok, [%Document{id: "a"}, %Document{id: "b"}]} =
             VectorStore.async_get_by_ids(store, ["a", "b"])
             |> Async.await()

    assert {:ok, [%Document{}]} =
             VectorStore.async_max_marginal_relevance_search(store, "alpha", k: 1)
             |> Async.await()

    assert {:ok, [%Document{}]} =
             VectorStore.async_max_marginal_relevance_search_by_vector(store, [1.0, 1.0, 1.0], k: 1)
             |> Async.await()

    assert :ok = VectorStore.async_delete(store, ["a"]) |> Async.await()
    assert {:ok, []} = VectorStore.get_by_ids(store, ["a"])

    assert {:error, %{type: :unsupported_vector_search_type}} =
             VectorStore.search(store, "alpha", :unsupported)
  end

  test "vectorstore add_documents supports explicit ids without mutating input documents" do
    # Translates langchain_core vectorstores/test_vectorstore.py::test_default_add_documents.
    store = ETS.new(embedding: %FakeEmbeddingModel{})
    original = Document.new!("baz", id: "7")

    assert {:ok, ["6"]} = VectorStore.add_documents(store, [original], ids: ["6"])
    assert original.id == "7"
    assert {:ok, [%Document{id: "6", content: "baz"}]} = VectorStore.get_by_ids(store, ["6"])

    assert {:ok, ["6"]} = VectorStore.add_documents(store, [Document.new!("updated")], ids: ["6"])
    assert {:ok, [%Document{id: "6", content: "updated"}]} = VectorStore.get_by_ids(store, ["6"])

    task = VectorStore.async_add_documents(store, [Document.new!("async", id: "8")])
    assert {:ok, ["8"]} = Async.await(task)
  end

  test "retriever async wrapper preserves ordered document results" do
    # Translates core in-memory indexer async retriever behavior to BeamWeaver async handles.
    store = ETS.new(embedding: %FakeEmbeddingModel{})
    assert {:ok, [_id]} = VectorStore.add_texts(store, ["standard retriever document"])
    retriever = VectorStore.as_retriever(store, k: 1)

    task = Retriever.async_retrieve(retriever, "standard")

    assert {:ok, [%Document{}]} = Async.await(task)
  end

  test "filter SQL generation supports equality, membership, comparison, and rejects unsupported operators" do
    assert {:ok, {sql, params}} =
             Filter.to_sql(%{"nested.rank" => %{gte: 2}, group: "a", tag: %{in: ["x", "y"]}}, 3)

    assert sql =~ "metadata #>> '{group}'"
    assert sql =~ "(metadata #>> '{nested,rank}')::numeric >="
    assert sql =~ "metadata #>> '{tag}' = ANY"
    assert "a" in params
    assert 2 in params
    assert ["x", "y"] in params

    assert {:error, %{type: :unsupported_vector_filter}} =
             Filter.to_sql(%{group: %{contains: "a"}})
  end

  test "EctoPostgres adapter emits migration SQL and uses query module boundary for add/search/delete" do
    {:ok, repo} = Agent.start_link(fn -> %{rows: %{}} end)

    store =
      EctoPostgres.new(
        repo: repo,
        query_module: __MODULE__.FakeSQL,
        table: "test_vectors",
        namespace: "tenant-a",
        embedding: %FakeEmbeddingModel{dimensions: 3},
        dimensions: 3
      )

    assert {:ok, [id]} =
             VectorStore.add_documents(store, [
               Document.new!("alpha document", metadata: %{group: "a"})
             ])

    assert is_binary(id)

    assert {:ok, [{%Document{content: "alpha document"}, score}]} =
             VectorStore.similarity_search_with_score(store, "alpha", k: 1)

    assert is_number(score)
    assert :ok = VectorStore.delete(store, [id])
    assert {:ok, []} = VectorStore.similarity_search(store, "alpha", k: 1)
  end

  defmodule FakeSQL do
    alias BeamWeaver.VectorStore.Scoring

    def query(repo, sql, params) do
      Agent.get_and_update(repo, fn state ->
        cond do
          String.starts_with?(String.trim(sql), "INSERT") ->
            [id, namespace, content, metadata, vector] = params

            row = %{
              id: id,
              namespace: namespace,
              content: content,
              metadata: metadata,
              embedding: parse_vector(vector)
            }

            state = put_in(state, [:rows, {namespace, id}], row)
            {{:ok, %{num_rows: 1, rows: []}}, state}

          String.starts_with?(String.trim(sql), "DELETE") ->
            [namespace, ids] = params
            rows = Map.drop(state.rows, Enum.map(ids, &{namespace, &1}))
            {{:ok, %{num_rows: length(ids), rows: []}}, %{state | rows: rows}}

          String.starts_with?(String.trim(sql), "SELECT") ->
            [namespace, vector_or_ids | _rest] = params

            rows =
              if is_list(vector_or_ids) do
                vector_or_ids
                |> Enum.flat_map(fn id ->
                  case Map.get(state.rows, {namespace, id}) do
                    nil -> []
                    row -> [[row.id, row.content, row.metadata, encode_vector(row.embedding), 0]]
                  end
                end)
              else
                query_vector = parse_vector(vector_or_ids)

                state.rows
                |> Map.values()
                |> Enum.filter(&(&1.namespace == namespace))
                |> Enum.map(fn row ->
                  score = Scoring.cosine(query_vector, row.embedding)
                  [row.id, row.content, row.metadata, encode_vector(row.embedding), score]
                end)
                |> Enum.sort_by(fn [_id, _content, _metadata, _embedding, score] -> -score end)
              end

            result = %{
              columns: ["id", "content", "metadata", "embedding", "score"],
              rows: rows
            }

            {{:ok, result}, state}

          true ->
            {{:ok, %{rows: []}}, state}
        end
      end)
    end

    defp parse_vector(value) do
      value
      |> String.trim_leading("[")
      |> String.trim_trailing("]")
      |> String.split(",", trim: true)
      |> Enum.map(fn part ->
        {number, _rest} = Float.parse(String.trim(part))
        number
      end)
    end

    defp encode_vector(vector),
      do: "[" <> Enum.map_join(vector, ",", &to_string/1) <> "]"
  end
end
