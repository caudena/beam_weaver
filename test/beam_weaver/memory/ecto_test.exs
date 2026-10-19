defmodule BeamWeaver.Memory.EctoTest do
  use ExUnit.Case, async: false

  @moduletag :postgres

  import BeamWeaver.TestSupport.Eventually

  alias BeamWeaver.Memory
  alias BeamWeaver.Memory.Ecto
  alias BeamWeaver.Memory.EctoTest.InterleavedQuery
  alias BeamWeaver.Memory.PutOp
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
    assert eventually(fn -> count_rows(table) == 0 end)
    assert :ok = Ecto.stop_ttl_sweeper(sweeper)
  end

  test "put applies the store default_ttl when no :ttl option is given" do
    {table, store} = new_store(default_ttl: 0.0001)

    assert {:ok, item} = Memory.put(store, [:ttl], :k, %{value: true})
    refute is_nil(item.expires_at)

    assert {:ok, sweeper} = Ecto.start_ttl_sweeper(store, interval: 10)
    assert eventually(fn -> count_rows(table) == 0 end)
    assert :ok = Ecto.stop_ttl_sweeper(sweeper)
  end

  test "refresh-on-read updates expires_at without bumping updated_at" do
    {_table, store} = new_store(default_ttl: 60, refresh_ttl: true)

    assert {:ok, item} = Memory.put(store, [:rt], :k, %{value: 1})
    Process.sleep(10)

    assert {:ok, read} = Memory.get(store, [:rt], :k)
    assert read.updated_at == item.updated_at
  end

  test "a refresh racing a put keeps the lifetime the put gave the record" do
    {table, store} = new_store()
    racing = Ecto.new(repo: PostgresRepo, table: table, refresh_ttl: true, query_module: InterleavedQuery)

    # Between the read and its refresh, the record is put again: once without
    # a lifetime, once with a longer one.
    for {ttl, value} <- [{nil, 2}, {600, 3}] do
      assert {:ok, _item} = Memory.put(store, ["notes"], "k", %{"v" => 1}, ttl: 5)

      InterleavedQuery.before("UPDATE", fn ->
        assert {:ok, _item} = Memory.put(store, ["notes"], "k", %{"v" => value}, ttl: ttl)
      end)

      assert {:ok, %{value: %{"v" => 1}}} = Memory.get(racing, ["notes"], "k")
      assert {:ok, %{value: %{"v" => ^value}} = item} = Memory.get(store, ["notes"], "k")
      assert item.ttl == ttl

      if ttl,
        do: assert(DateTime.diff(item.expires_at, DateTime.utc_now(), :minute) >= 590),
        else: assert(is_nil(item.expires_at))
    end
  end

  test "reading an expired record while it is put again keeps the new value" do
    {table, store} = new_store()
    racing = Ecto.new(repo: PostgresRepo, table: table, query_module: InterleavedQuery)

    assert {:ok, _item} = Memory.put(store, ["notes"], "k", %{"v" => "old"}, ttl: 5)

    {:ok, _result} =
      Elixir.Ecto.Adapters.SQL.query(PostgresRepo, "UPDATE #{table} SET expires_at = now() - interval '1 minute'", [])

    # Between the read of the expired record and its delete, the record is put again.
    InterleavedQuery.before("DELETE", fn ->
      assert {:ok, _item} = Memory.put(store, ["notes"], "k", %{"v" => "new"})
    end)

    assert :error = Memory.get(racing, ["notes"], "k")
    assert {:ok, %{value: %{"v" => "new"}}} = Memory.get(store, ["notes"], "k")
  end

  test "a put that fails inside a batch returns its error, and the other operations still run" do
    {_table, store} = new_store()

    assert [{:error, _error}, nil] =
             Memory.batch(store, [
               %PutOp{namespace: ["notes"], key: "bad", value: {:not, :json}},
               %PutOp{namespace: ["notes"], key: "good", value: %{"v" => 1}}
             ])

    assert ["good"] = Memory.yield_keys(store, ["notes"])
  end

  test "refresh_ttl: nil is the default, false, and other values raise" do
    {_table, store} = new_store(refresh_ttl: nil)

    assert {:ok, item} = Memory.put(store, ["notes"], "k", %{"v" => 1}, ttl: 5)
    assert [%{expires_at: expires_at}] = Memory.search(store, ["notes"])
    assert expires_at == item.expires_at
    assert %Ecto{refresh_ttl: false} = store

    assert_raise ArgumentError, ~r/:refresh_ttl/, fn -> Ecto.new(repo: PostgresRepo, refresh_ttl: "yes") end
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

defmodule BeamWeaver.Memory.EctoTest.InterleavedQuery do
  # A store's `:query_module` that runs a function right before the next
  # statement starting with a given prefix, to interleave another writer.

  def before(prefix, fun), do: Process.put(__MODULE__, {prefix, fun})

  def query(repo, sql, params) do
    with {prefix, fun} <- Process.get(__MODULE__),
         true <- String.starts_with?(String.trim_leading(sql), prefix) do
      Process.delete(__MODULE__)
      fun.()
    end

    repo.query(sql, params)
  end
end
