defmodule BeamWeaver.StructuredQueryTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.Document
  alias BeamWeaver.Models.FakeEmbeddingModel
  alias BeamWeaver.StructuredQuery
  alias BeamWeaver.VectorStore
  alias BeamWeaver.VectorStore.ETS
  alias BeamWeaver.VectorStore.Filter

  defmodule EchoVisitor do
    def visit_comparison(comparison, _opts), do: {:comparison, comparison.attribute}
    def visit_operation(operation, _opts), do: {:operation, operation.operator}
    def visit_structured_query(query, _opts), do: {:query, query.query}
  end

  test "builds comparisons, operations, and retrieval options" do
    assert {:ok, year} = StructuredQuery.comparison(:gte, :year, 2024)
    assert {:ok, tag} = StructuredQuery.comparison("in", "tag", ["ai", "beam"])
    assert {:ok, filter} = StructuredQuery.operation(:and, [year, tag])
    assert {:ok, query} = StructuredQuery.new("runtime", filter, limit: 2)

    assert {:ok,
            {"runtime",
             [
               k: 2,
               filter: %{
                 "$and" => [
                   %{"year" => %{"$gte" => 2024}},
                   %{"tag" => %{"$in" => ["ai", "beam"]}}
                 ]
               }
             ]}} = StructuredQuery.to_retrieval(query)
  end

  test "compiled filters work with vector-store metadata filtering" do
    assert {:ok, recent} = StructuredQuery.comparison(:gte, :year, 2024)
    assert {:ok, topic} = StructuredQuery.comparison(:like, :title, "%Beam%")
    assert {:ok, filter} = StructuredQuery.operation(:and, [recent, topic])
    assert {:ok, filter_map} = StructuredQuery.to_filter(filter)

    store = ETS.new(embedding: %FakeEmbeddingModel{dimensions: 6})

    assert {:ok, _ids} =
             VectorStore.add_documents(store, [
               Document.new!("beam runtime",
                 id: "beam",
                 metadata: %{year: 2025, title: "Beam notes"}
               ),
               Document.new!("python runtime",
                 id: "py",
                 metadata: %{year: 2025, title: "Python notes"}
               ),
               Document.new!("old beam",
                 id: "old",
                 metadata: %{year: 2020, title: "Beam archive"}
               )
             ])

    assert {:ok, [%Document{id: "beam"}]} =
             VectorStore.similarity_search(store, "runtime", k: 3, filter: filter_map)
  end

  test "filter matcher supports logical, negative, containment, and like operators" do
    metadata = %{year: 2025, tags: ["ai", "beam"], title: "Beam runtime notes"}

    assert Filter.match?(metadata, %{
             "$and" => [%{"year" => %{"$gt" => 2024}}, %{"tags" => %{"$contain" => "beam"}}]
           })

    assert Filter.match?(metadata, %{"title" => %{"$like" => "%runtime%"}})
    assert Filter.match?(metadata, %{"year" => %{"$ne" => 2020}})
    refute Filter.match?(metadata, %{"$not" => %{"tags" => %{"$contain" => "beam"}}})
  end

  test "accept dispatches to modules and function maps" do
    assert {:ok, comparison} = StructuredQuery.comparison(:eq, :source, "docs")
    assert {:ok, operation} = StructuredQuery.operation(:not, [comparison])
    assert {:ok, query} = StructuredQuery.new("docs", operation)

    assert {:comparison, :source} = StructuredQuery.accept(comparison, EchoVisitor)
    assert {:operation, :not} = StructuredQuery.accept(operation, EchoVisitor)
    assert {:query, "docs"} = StructuredQuery.accept(query, EchoVisitor)

    visitor = %{visit_comparison: fn comparison, _opts -> {:ok, comparison.value} end}
    assert {:ok, "docs"} = StructuredQuery.accept(comparison, visitor)
  end

  test "invalid operators and filters return tagged errors" do
    assert {:error, error} = StructuredQuery.comparison(:regex, :title, "beam")
    assert error.type == :invalid_structured_query

    assert {:error, error} = StructuredQuery.operation(:not, [])
    assert error.type == :invalid_structured_query

    assert {:error, error} = StructuredQuery.new(:not_a_query)
    assert error.type == :invalid_structured_query
  end
end
