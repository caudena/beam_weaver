defmodule BeamWeaver.TestSupport.Conformance.RecordManagerCase do
  @moduledoc """
  Shared behavior checks for indexing record managers.
  """

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      use ExUnit.Case, async: true

      alias BeamWeaver.Indexing.Record
      alias BeamWeaver.Indexing.RecordManager

      @beamweaver_record_manager Keyword.fetch!(opts, :record_manager)

      test "record manager stores, lists, filters, and deletes records" do
        manager = beamweaver_standard_value(@beamweaver_record_manager)

        record = %Record{
          id: "doc-1",
          source_id: "source-a",
          hash: "hash-1",
          namespace: :case,
          metadata: %{kind: :standard}
        }

        assert :ok = RecordManager.put(manager, record, namespace: :case)
        assert {:ok, stored} = RecordManager.get(manager, "doc-1", namespace: :case)

        assert %{id: "doc-1", source_id: "source-a", hash: "hash-1", metadata: %{kind: :standard}} =
                 stored

        assert {:ok, [listed]} =
                 RecordManager.list(manager, namespace: :case, source_ids: ["source-a"])

        assert listed.id == "doc-1"
        assert :ok = RecordManager.delete(manager, ["doc-1"], namespace: :case)
        assert {:ok, nil} = RecordManager.get(manager, "doc-1", namespace: :case)
      end

      defp beamweaver_standard_value(value),
        do: BeamWeaver.TestSupport.Conformance.Subject.standard_value(value)
    end
  end
end
