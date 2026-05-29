defmodule BeamWeaver.RecordManagerEctoPostgresTest do
  use ExUnit.Case, async: false

  @moduletag :postgres

  alias BeamWeaver.Indexing.Record
  alias BeamWeaver.Indexing.RecordManager
  alias BeamWeaver.Indexing.RecordManager.EctoPostgres
  alias BeamWeaver.Test.LivePostgres
  alias BeamWeaver.Test.PostgresRepo

  setup do
    assert LivePostgres.available?()
    :ok
  end

  test "EctoPostgres record manager uses real Postgres for put/get/list/delete" do
    table = LivePostgres.unique_table("bw_record_manager_test")
    version = LivePostgres.migrate(adapters: [{:record_manager, table: table}])

    on_exit(fn ->
      LivePostgres.drop_tables([table])
      LivePostgres.clear_migration(version)
    end)

    manager =
      EctoPostgres.new(
        repo: PostgresRepo,
        table: table,
        namespace: :tenant
      )

    record = %Record{
      id: "doc-1",
      source_id: "source-a",
      hash: "hash-a",
      namespace: :tenant,
      metadata: %{rank: 1}
    }

    assert :ok = RecordManager.put(manager, record)

    assert {:ok, %Record{id: "doc-1", source_id: "source-a", metadata: %{"rank" => 1}}} =
             RecordManager.get(manager, "doc-1")

    assert {:ok, [%Record{id: "doc-1"}]} =
             RecordManager.list(manager, source_ids: ["source-a"])

    assert :ok = RecordManager.delete(manager, ["doc-1"])
    assert {:ok, nil} = RecordManager.get(manager, "doc-1")
  end
end
