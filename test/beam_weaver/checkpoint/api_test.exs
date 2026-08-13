defmodule BeamWeaver.Checkpoint.APITest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Checkpoint
  alias BeamWeaver.Checkpoint.ETS
  alias BeamWeaver.Core.Error

  defmodule ErrorSaver do
    @behaviour BeamWeaver.Checkpoint.Saver

    defstruct []

    @impl true
    def fetch_tuple(_saver, _config), do: {:error, :storage_unavailable}

    @impl true
    def list_result(_saver, _config, _opts), do: {:error, :storage_unavailable}

    @impl true
    def get_tuple(_saver, _config), do: nil

    @impl true
    def list(_saver, _config, _opts), do: []

    @impl true
    def put(_saver, _config, _checkpoint, _metadata, _versions), do: {:error, :unsupported}

    @impl true
    def put_writes(_saver, _config, _writes, _task_id, _task_path),
      do: {:error, :unsupported}

    @impl true
    def get_delta_channel_history(_saver, _config, _channels, _opts), do: %{}

    @impl true
    def delete_thread(_saver, _thread_id), do: :ok

    @impl true
    def delete_for_runs(_saver, _run_ids), do: :ok

    @impl true
    def copy_thread(_saver, _source_thread_id, _target_thread_id), do: :ok

    @impl true
    def prune(_saver, _thread_ids, _opts), do: :ok

    @impl true
    def next_version(_saver, current, _channel), do: current
  end

  defmodule RaisingSaver do
    defstruct []

    def get_tuple(_saver, _config), do: raise("database disconnected")
    def list(_saver, _config, _opts), do: raise("database disconnected")
  end

  test "read APIs preserve adapter errors" do
    saver = %ErrorSaver{}

    assert {:error, :storage_unavailable} = Checkpoint.fetch_tuple(saver, config())
    assert {:error, :storage_unavailable} = Checkpoint.list_result(saver, config())

    assert_raise RuntimeError, ":storage_unavailable", fn ->
      Checkpoint.get_tuple(saver, config())
    end

    assert_raise RuntimeError, ":storage_unavailable", fn ->
      Checkpoint.list(saver, config())
    end
  end

  test "legacy saver exceptions become typed read errors" do
    saver = %RaisingSaver{}

    assert {:error, %Error{type: :checkpoint_read_failed, message: "database disconnected"}} =
             Checkpoint.fetch_tuple(saver, config())

    assert {:error, %Error{type: :checkpoint_read_failed, message: "database disconnected"}} =
             Checkpoint.list_result(saver, config())
  end

  test "combined persistence fails before writing when the saver is not atomic" do
    saver = ETS.new()
    config = config()
    checkpoint = %{"id" => "checkpoint-1", "channel_values" => %{"value" => 1}}

    assert {:error, %Error{type: :atomic_checkpoint_write_unsupported}} =
             Checkpoint.put_checkpoint_with_writes(
               saver,
               config,
               checkpoint,
               %{},
               %{},
               [{"value", 1}]
             )

    assert {:ok, nil} = Checkpoint.fetch_tuple(saver, config)
  end

  test "ETS batch is atomically visible with pending writes" do
    saver = ETS.new()

    entries = [
      entry("root", nil, 1, [{"task", "value", 10}]),
      entry("child", "root", 2, [{"task", "value", 20}])
    ]

    assert {:ok, [_root, child]} = Checkpoint.put_many(saver, entries)

    assert {:ok, %{checkpoint: %{"id" => "child"}, pending_writes: pending}} =
             Checkpoint.fetch_tuple(saver, child)

    assert [{"task", "value", 20}] = pending

    invalid = %{entry("broken", "child", 99, []) | writes: [:invalid]}

    assert {:error, %Error{type: :invalid_checkpoint_batch}} =
             Checkpoint.put_many(saver, [entry("next", "child", 3, []), invalid])

    assert {:ok, nil} = Checkpoint.fetch_tuple(saver, exact_config("next"))
    assert {:ok, nil} = Checkpoint.fetch_tuple(saver, exact_config("broken"))

    assert {:error, %Error{type: :checkpoint_conflict}} =
             Checkpoint.put_many(saver, [entry("root", nil, 99, [])])
  end

  test "latest and list order use persisted commit order, not checkpoint ids" do
    saver = ETS.new()

    assert {:ok, _} = Checkpoint.put_many(saver, [entry("z", nil, 1, [])])
    assert {:ok, _} = Checkpoint.put_many(saver, [entry("a", "z", 2, [])])

    assert {:ok, %{checkpoint: %{"id" => "a"}}} = Checkpoint.fetch_tuple(saver, config())

    assert {:ok, tuples} = Checkpoint.list_result(saver, config())
    assert Enum.map(tuples, & &1.checkpoint["id"]) == ["a", "z"]
  end

  test "bounded fork copies only the selected lineage" do
    saver = ETS.new()

    assert {:ok, _} =
             Checkpoint.put_many(saver, [
               entry("root", nil, 1, []),
               entry("middle", "root", 2, []),
               entry("later", "middle", 3, [])
             ])

    assert {:ok, forked} =
             Checkpoint.fork_at(saver, exact_config("middle"), "forked", max_checkpoints: 3)

    assert forked["configurable"]["checkpoint_id"] == "middle"

    assert {:ok, tuples} =
             Checkpoint.list_result(saver, %{"configurable" => %{"thread_id" => "forked"}})

    assert Enum.map(tuples, & &1.checkpoint["id"]) == ["middle", "root"]

    assert {:error, %Error{type: :checkpoint_fork_too_large}} =
             Checkpoint.fork_at(saver, exact_config("middle"), "too-small", max_checkpoints: 1)
  end

  defp config do
    %{"configurable" => %{"thread_id" => "checkpoint-api-test"}}
  end

  defp exact_config(checkpoint_id) do
    put_in(config(), ["configurable", "checkpoint_id"], checkpoint_id)
  end

  defp entry(id, parent_id, value, writes) do
    config =
      if parent_id do
        exact_config(parent_id)
      else
        config()
      end

    %{
      config: config,
      checkpoint: %{
        "id" => id,
        "channel_values" => %{"value" => value},
        "channel_versions" => %{"value" => value}
      },
      metadata: %{},
      versions: %{"value" => value},
      writes: writes
    }
  end
end
