defmodule BeamWeaver.TestSupport.Conformance.IndexingCase do
  @moduledoc """
  Shared behavior checks for indexing orchestration.
  """

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      use ExUnit.Case, async: true

      alias BeamWeaver.Core.Document
      alias BeamWeaver.Indexing
      alias BeamWeaver.VectorStore

      @beamweaver_vector_store Keyword.fetch!(opts, :vector_store)
      @beamweaver_record_manager Keyword.fetch!(opts, :record_manager)

      test "indexing skips unchanged documents through the record manager" do
        store = beamweaver_standard_value(@beamweaver_vector_store)
        records = beamweaver_standard_value(@beamweaver_record_manager)

        docs = [
          Document.new!("standard indexing document", id: "std-1", metadata: %{source: "std"})
        ]

        assert {:ok, first} = Indexing.index(store, docs, record_manager: records)
        assert first.added == 1

        assert {:ok, second} = Indexing.index(store, docs, record_manager: records)
        assert second.skipped == 1
        assert second.added == 0

        assert {:ok, [_doc]} = VectorStore.similarity_search(store, "standard", k: 1)
      end

      defp beamweaver_standard_value(value),
        do: BeamWeaver.TestSupport.Conformance.Subject.standard_value(value)
    end
  end
end
