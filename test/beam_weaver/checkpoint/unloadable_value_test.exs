defmodule BeamWeaver.Checkpoint.UnloadableValueTest do
  # A thread saved with a struct that can't be rebuilt any more, because its
  # tag was taken out of the registry or its module was removed, still loads:
  # the struct comes back as a map of its fields and the rest of the state as
  # it was saved.
  use ExUnit.Case, async: false

  @moduletag capture_log: true

  alias BeamWeaver.Checkpoint
  alias BeamWeaver.Checkpoint.ETS
  alias BeamWeaver.Checkpoint.Ecto, as: EctoCheckpoint
  alias BeamWeaver.Graph
  alias BeamWeaver.Graph.Compiled
  alias BeamWeaver.Serialization.Registry
  alias BeamWeaver.Test.LiveSQLite
  alias BeamWeaver.Test.SQLiteRepo

  defmodule Order do
    defstruct [:id, :qty]
  end

  defp graph(saver) do
    Graph.new()
    |> Graph.add_reducer(:log, &(&1 ++ &2))
    |> Graph.add_node(:record, fn _state -> %{log: ["recorded"]} end)
    |> Graph.add_edge(Graph.start(), :record)
    |> Graph.add_edge(:record, Graph.end_node())
    |> Graph.compile!(checkpointer: saver)
  end

  test "ets: a thread holding a struct keeps it, since ETS stores values as they are" do
    saver = ETS.new()
    config = %{"configurable" => %{"thread_id" => "orders"}}
    order = %Order{id: "A-1001", qty: 2}

    assert {:ok, _result} = Compiled.invoke(graph(saver), %{order: order, log: []}, config: config)
    assert {:ok, %{values: %{order: ^order, log: ["recorded"]}}} = Compiled.get_state(graph(saver), config)
  end

  for codec <- [:json, :encrypted],
      {change, types} <- [
        {"its tag is no longer registered", quote(do: %{})},
        {"its module is gone", quote(do: %{"app.order" => __MODULE__.RemovedOrder})}
      ] do
    test "sqlite #{codec}: a thread holding a struct loads when #{change}" do
      tables = tables()
      key = :crypto.strong_rand_bytes(32)
      writer = saver(tables, unquote(codec), key, %{"app.order" => Order})
      reader = saver(tables, unquote(codec), key, unquote(types))
      config = %{"configurable" => %{"thread_id" => "orders"}}

      input = %{order: %Order{id: "A-1001", qty: 2}, status: :open, log: []}
      assert {:ok, _result} = Compiled.invoke(graph(writer), input, config: config)

      order = %{"id" => "A-1001", "qty" => 2}

      assert {:ok, %{values: %{order: ^order, status: :open, log: ["recorded"]}}} =
               Compiled.get_state(graph(reader), config)

      assert %{checkpoint: %{"channel_values" => %{order: ^order}}} = Checkpoint.get_tuple(reader, config)

      assert {:ok, %{order: ^order, log: ["recorded", "recorded"]}} =
               Compiled.invoke(graph(reader), %{log: []}, config: config)
    end
  end

  defp tables do
    checkpoints = LiveSQLite.unique_table("bw_unloadable_checkpoints")
    writes = LiveSQLite.unique_table("bw_unloadable_writes")

    version =
      LiveSQLite.migrate(
        repo: SQLiteRepo,
        adapters: [{:checkpoint, checkpoints_table: checkpoints, writes_table: writes}]
      )

    on_exit(fn ->
      LiveSQLite.drop_tables([writes, checkpoints])
      LiveSQLite.clear_migration(version)
    end)

    {checkpoints, writes}
  end

  defp saver({checkpoints, writes}, codec, key, types) do
    registry = Registry.new(types: types)

    serialization =
      case codec do
        :json -> [registry: registry]
        :encrypted -> [codec: BeamWeaver.Serialization.Encrypted, encryption_key: key, registry: registry]
      end

    EctoCheckpoint.new(
      repo: SQLiteRepo,
      checkpoints_table: checkpoints,
      writes_table: writes,
      serialization: serialization
    )
  end
end
