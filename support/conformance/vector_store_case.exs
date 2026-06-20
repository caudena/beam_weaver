defmodule BeamWeaver.TestSupport.Conformance.VectorStoreCase do
  @moduledoc """
  Shared ExUnit checks for vector stores.
  """

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      use ExUnit.Case, async: true

      alias BeamWeaver.Core.Document
      alias BeamWeaver.VectorStore

      @beamweaver_store Keyword.fetch!(opts, :store)

      test "vector store adds, searches, and deletes documents" do
        store = beamweaver_standard_value(@beamweaver_store)
        doc = Document.new!("standard vector document", metadata: %{source: "case"})

        assert {:ok, [id]} = VectorStore.add_documents(store, [doc])
        assert {:ok, [%Document{}]} = VectorStore.similarity_search(store, "standard", k: 1)
        assert :ok = VectorStore.delete(store, [id])
        assert {:ok, []} = VectorStore.similarity_search(store, "standard", k: 1)
      end

      defp beamweaver_standard_value(value),
        do: BeamWeaver.TestSupport.Conformance.Subject.standard_value(value)
    end
  end
end
