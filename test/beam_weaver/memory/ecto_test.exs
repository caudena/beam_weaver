defmodule BeamWeaver.Memory.EctoTest do
  use ExUnit.Case, async: false

  @moduletag :postgres

  alias BeamWeaver.Memory
  alias BeamWeaver.Memory.Ecto
  alias BeamWeaver.Test.LivePostgres
  alias BeamWeaver.Test.PostgresRepo

  setup do
    assert LivePostgres.available?()
    :ok
  end

  test "uses the memory store contract through an Ecto/Postgres query boundary" do
    {_table, store} = new_store()

    assert {:ok, item} =
             Memory.put(store, [:users, "u1"], :profile, %{name: "Ada"}, metadata: %{kind: "profile"})

    assert item.namespace == ["users", "u1"]
    assert item.key == "profile"

    assert {:ok, %{value: %{"name" => "Ada"}}} = Memory.get(store, [:users, "u1"], :profile)
    assert [%{namespace: ["users", "u1"]}] = Memory.search(store, [:users])
    assert [["users", "u1"]] = Memory.list_namespaces(store, prefix: ["users"])

    assert :ok = Memory.delete(store, [:users, "u1"], :profile)
    assert Memory.get(store, [:users, "u1"], :profile) == :error
  end

  test "caller-supervised TTL sweeper removes expired rows through the adapter boundary" do
    {table, store} = new_store()

    assert {:ok, _item} = Memory.put(store, [:ttl], :short, %{value: true}, ttl: 0.0001)
    assert 1 = count_rows(table)

    assert {:ok, sweeper} = Ecto.start_ttl_sweeper(store, interval: 10)
    Process.sleep(30)
    assert :ok = Ecto.stop_ttl_sweeper(sweeper)

    assert 0 = count_rows(table)
  end

  test "put applies the store default_ttl when no :ttl option is given" do
    {table, store} = new_store(default_ttl: 0.0001)

    assert {:ok, item} = Memory.put(store, [:ttl], :k, %{value: true})
    refute is_nil(item.expires_at)

    assert {:ok, sweeper} = Ecto.start_ttl_sweeper(store, interval: 10)
    Process.sleep(30)
    assert :ok = Ecto.stop_ttl_sweeper(sweeper)

    assert 0 = count_rows(table)
  end

  test "refresh-on-read updates expires_at without bumping updated_at" do
    {_table, store} = new_store(default_ttl: 60, refresh_on_read?: true)

    assert {:ok, item} = Memory.put(store, [:rt], :k, %{value: 1})
    Process.sleep(10)

    assert {:ok, read} = Memory.get(store, [:rt], :k)
    assert read.updated_at == item.updated_at
  end

  defp new_store(opts \\ []) do
    table = LivePostgres.unique_table("bw_ecto_memory")
    version = LivePostgres.migrate(adapters: [{:memory, table: table}])

    on_exit(fn ->
      LivePostgres.drop_tables([table])
      LivePostgres.clear_migration(version)
    end)

    {table, Ecto.new(Keyword.merge([repo: PostgresRepo, table: table], opts))}
  end

  defp count_rows(table) do
    {:ok, %{rows: [[count]]}} =
      Elixir.Ecto.Adapters.SQL.query(PostgresRepo, "SELECT count(*) FROM #{table}", [])

    count
  end
end
