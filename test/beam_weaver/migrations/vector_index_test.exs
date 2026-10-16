defmodule BeamWeaver.Migrations.VectorIndexTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Migrations

  test "a vector store index takes at most 2,000 dimensions, and index: false takes any" do
    assert Migrations.current_version(adapters: [{:vector_store, dimensions: 3_072, index: false}]) == 1
    assert Migrations.current_version(adapters: [{:vector_store, dimensions: 2_000, index: :hnsw}]) == 1

    assert_raise ArgumentError, ~r/dimensions: 3072. Pass index: false/, fn ->
      Migrations.current_version(adapters: [{:vector_store, dimensions: 3_072}])
    end

    assert_raise ArgumentError, ~r/must be :ivfflat, :hnsw or false/, fn ->
      Migrations.current_version(adapters: [{:vector_store, index: :none}])
    end
  end
end
