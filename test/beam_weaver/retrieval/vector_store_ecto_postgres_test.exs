defmodule BeamWeaver.VectorStoreEctoPostgresTest do
  use ExUnit.Case, async: false

  alias BeamWeaver.Core.Document
  alias BeamWeaver.Models.FakeEmbeddingModel
  alias BeamWeaver.Retriever
  alias BeamWeaver.Test.LivePostgres
  alias BeamWeaver.Test.PostgresRepo
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

  test "vectorstore add_texts delegates through document storage" do
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

    assert {:ok, ["5", "6"]} = VectorStore.add_texts(store, ["foo", "bar"], ids: ["5", "6"])
  end

  test "vectorstore facade covers search, get, MMR, and delete" do
    store = ETS.new(embedding: %FakeEmbeddingModel{})

    assert {:ok, ["a", "b"]} =
             VectorStore.add_texts(store, ["alpha document", "beta document"],
               ids: ["a", "b"],
               metadatas: [%{kind: "a"}, %{kind: "b"}]
             )

    assert {:ok, [%Document{id: "a"}]} = VectorStore.similarity_search(store, "alpha", k: 1)

    assert {:ok, [{%Document{}, vector_score}]} =
             VectorStore.similarity_search_with_score_by_vector(store, [1.0, 1.0, 1.0], k: 1)

    assert is_number(vector_score)

    assert {:ok, [{%Document{id: "a"}, score}]} = VectorStore.similarity_search_with_score(store, "alpha", k: 1)
    assert is_number(score)

    assert {:ok, [{%Document{id: "a"}, ^score}]} =
             VectorStore.similarity_search_with_relevance_scores(store, "alpha",
               k: 1,
               score_threshold: score
             )

    assert {:ok, [%Document{id: "a"}]} =
             VectorStore.search(store, "alpha", :similarity_score,
               k: 2,
               score_threshold: score
             )

    assert {:ok, [%Document{id: "a"}, %Document{id: "b"}]} = VectorStore.get_by_ids(store, ["a", "b"])

    assert {:ok, [%Document{}]} = VectorStore.max_marginal_relevance_search(store, "alpha", k: 1)
    assert {:ok, [%Document{}]} = VectorStore.max_marginal_relevance_search_by_vector(store, [1.0, 1.0, 1.0], k: 1)

    assert :ok = VectorStore.delete(store, ["a"])
    assert {:ok, []} = VectorStore.get_by_ids(store, ["a"])

    assert {:error, %{type: :unsupported_vector_search_type}} =
             VectorStore.search(store, "alpha", :unsupported)
  end

  test "vectorstore add_documents supports explicit ids without mutating input documents" do
    store = ETS.new(embedding: %FakeEmbeddingModel{})
    original = Document.new!("baz", id: "7")

    assert {:ok, ["6"]} = VectorStore.add_documents(store, [original], ids: ["6"])
    assert original.id == "7"
    assert {:ok, [%Document{id: "6", content: "baz"}]} = VectorStore.get_by_ids(store, ["6"])

    assert {:ok, ["6"]} = VectorStore.add_documents(store, [Document.new!("updated")], ids: ["6"])
    assert {:ok, [%Document{id: "6", content: "updated"}]} = VectorStore.get_by_ids(store, ["6"])

    assert {:ok, ["8"]} = VectorStore.add_documents(store, [Document.new!("async", id: "8")])
  end

  test "retriever wrapper returns vectorstore search results" do
    store = ETS.new(embedding: %FakeEmbeddingModel{})
    assert {:ok, [_id]} = VectorStore.add_texts(store, ["standard retriever document"])
    retriever = VectorStore.as_retriever(store, k: 1)

    assert {:ok, [%Document{}]} = Retriever.retrieve(retriever, "standard")
  end

  test "filter SQL generation supports equality, membership, comparison, and rejects unsupported operators" do
    assert {:ok, {sql, params}} =
             Filter.to_sql(%{"nested.rank" => %{gte: 2}, group: "a", tag: %{in: ["x", "y"]}}, 3)

    assert sql =~ "metadata #>> $"
    assert sql =~ "::text[]"
    refute sql =~ "#>> '{"
    assert ["group"] in params
    assert ["nested", "rank"] in params
    assert ["tag"] in params
    assert "a" in params
    assert 2 in params
    assert ["x", "y"] in params

    assert {:error, %{type: :unsupported_vector_filter}} =
             Filter.to_sql(%{group: %{contains: "a"}}, 1)
  end

  @tag :postgres
  test "EctoPostgres adapter uses real Postgres for add/search/delete" do
    assert LivePostgres.available?()

    table = LivePostgres.unique_table("bw_vector_store_test")
    version = LivePostgres.migrate(adapters: [{:vector_store, table: table, dimensions: 3}])

    on_exit(fn ->
      LivePostgres.drop_tables([table])
      LivePostgres.clear_migration(version)
    end)

    store =
      EctoPostgres.new(
        repo: PostgresRepo,
        table: table,
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

    assert {:ok, [%Document{content: "alpha document"}]} =
             VectorStore.similarity_search(store, "alpha", k: 1, filter: %{"group" => "a"})

    assert {:ok, []} =
             VectorStore.similarity_search(store, "alpha",
               k: 1,
               filter: %{"x}' AND '1'='1' -- " => "y"}
             )

    assert :ok = VectorStore.delete(store, [id])
    assert {:ok, []} = VectorStore.similarity_search(store, "alpha", k: 1)
  end

  @tag :postgres
  test "EctoPostgres and ETS match the same documents for $contain and $like on every value type" do
    assert LivePostgres.available?()

    table = LivePostgres.unique_table("bw_vector_filter_test")
    version = LivePostgres.migrate(adapters: [{:vector_store, table: table, dimensions: 3}])

    on_exit(fn ->
      LivePostgres.drop_tables([table])
      LivePostgres.clear_migration(version)
    end)

    embedding = %FakeEmbeddingModel{dimensions: 3}

    postgres =
      EctoPostgres.new(repo: PostgresRepo, table: table, namespace: "filters", embedding: embedding, dimensions: 3)

    ets = ETS.new(embedding: embedding)

    values = %{
      "text" => "Hello World",
      "percent" => "50% off",
      "percent_lookalike" => "500 off",
      "underscore" => "a_b",
      "underscore_lookalike" => "axb",
      "backslash" => "a\\b",
      "plain_b" => "ab",
      "number" => 12,
      "boolean" => true,
      "list" => ["red", 12, true],
      "object" => %{"red" => 1},
      "null" => nil
    }

    documents =
      [Document.new!("missing", id: "missing", metadata: %{})] ++
        for({id, value} <- values, do: Document.new!(id, id: id, metadata: %{"v" => value}))

    for store <- [postgres, ets], do: assert({:ok, _ids} = VectorStore.add_documents(store, documents))

    all_ids = documents |> Enum.map(& &1.id) |> Enum.sort()

    cases = [
      {%{"v" => %{"$contain" => "WORLD"}}, ["text"]},
      {%{"v" => %{"$contain" => "0% o"}}, ["percent"]},
      {%{"v" => %{"$contain" => "_b"}}, ["underscore"]},
      {%{"v" => %{"$contain" => "\\b"}}, ["backslash"]},
      {%{"v" => %{"$contain" => "red"}}, ["list"]},
      {%{"v" => %{"$contain" => "RED"}}, []},
      {%{"v" => %{"$contain" => 12}}, ["list"]},
      {%{"v" => %{"$contain" => true}}, ["list"]},
      {%{"v" => %{"$contain" => "1"}}, []},
      {%{"$not" => %{"v" => %{"$contain" => "red"}}}, all_ids -- ["list"]},
      {%{"v" => %{"$like" => "hello%"}}, ["text"]},
      {%{"v" => %{"$like" => "12"}}, []},
      {%{"v" => %{"$like" => "true"}}, []},
      {%{"v" => %{"$like" => "%red%"}}, []},
      {%{"$not" => %{"v" => %{"$like" => "%red%"}}}, all_ids}
    ]

    # Each entry is {filter, Postgres ids, ETS ids}.
    assert for({filter, _expected} <- cases, do: {filter, matching_ids(postgres, filter), matching_ids(ets, filter)}) ==
             for({filter, expected} <- cases, do: {filter, expected, expected})
  end

  defp matching_ids(store, filter) do
    assert {:ok, documents} = VectorStore.similarity_search(store, "query", k: 50, filter: filter)
    documents |> Enum.map(& &1.id) |> Enum.sort()
  end
end
