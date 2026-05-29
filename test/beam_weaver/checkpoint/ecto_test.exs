defmodule BeamWeaver.Checkpoint.EctoTest do
  use ExUnit.Case, async: false

  @moduletag :postgres

  alias BeamWeaver.Checkpoint
  alias BeamWeaver.Checkpoint.Ecto
  alias BeamWeaver.Core.Async
  alias BeamWeaver.Core.ContentBlock
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Graph.Channels.DeltaSnapshot
  alias BeamWeaver.Test.LivePostgres
  alias BeamWeaver.Test.PostgresRepo

  setup do
    assert LivePostgres.available?()
    :ok
  end

  test "uses the saver contract through an Ecto/Postgres query boundary" do
    saver = new_saver()
    config = %{"configurable" => %{"thread_id" => "ecto-thread"}}

    assert {:ok, next_config} =
             Checkpoint.put(
               saver,
               config,
               %{"channel_values" => %{step: 1}},
               %{source: "loop"},
               %{step: 1}
             )

    assert :ok = Checkpoint.put_writes(saver, next_config, [{"step", 1}], "task-1", "node:step")

    assert %{
             checkpoint: %{"channel_values" => %{"step" => 1}},
             pending_writes: pending_writes,
             pending_write_paths: pending_write_paths
           } =
             Checkpoint.get_tuple(saver, config)

    assert pending_writes == [{"task-1", "step", 1}]
    assert pending_write_paths == [{"task-1", "step", "node:step"}]
    assert [%{checkpoint: %{"channel_values" => %{"step" => 1}}}] = Checkpoint.list(saver, config)
  end

  test "serializes BeamWeaver structs across the JSON query boundary" do
    saver = new_saver()
    config = %{"configurable" => %{"thread_id" => "ecto-struct-thread"}}

    user_message =
      Message.user("hello",
        metadata: %{source: :unit},
        artifacts: [ContentBlock.text("artifact")]
      )

    assert {:ok, next_config} =
             Checkpoint.put(
               saver,
               config,
               %{
                 "channel_values" => %{
                   "messages" => [user_message],
                   "snapshot" => %DeltaSnapshot{value: ["seed"]},
                   "block" => ContentBlock.text("inline block")
                 }
               },
               %{source: "loop"},
               %{}
             )

    assert :ok =
             Checkpoint.put_writes(
               saver,
               next_config,
               [{"messages", Message.assistant("pending")}],
               "task-message"
             )

    assert %{
             checkpoint: %{
               "channel_values" => %{
                 "messages" => [%Message{role: :user, metadata: %{"source" => :unit}}],
                 "snapshot" => %DeltaSnapshot{value: ["seed"]},
                 "block" => %ContentBlock.Text{text: "inline block"}
               }
             },
             pending_writes: [{"task-message", "messages", %Message{role: :assistant, content: "pending"}}]
           } = Checkpoint.get_tuple(saver, next_config)
  end

  test "supports shallow saver semantics through the same checkpoint facade" do
    saver = new_saver(shallow?: true)
    config = %{"configurable" => %{"thread_id" => "shallow-thread"}}

    assert {:ok, first_config} =
             Checkpoint.put(
               saver,
               config,
               %{"id" => "cp-1", "channel_values" => %{step: 1}},
               %{source: "loop"},
               %{step: 1}
             )

    assert :ok = Checkpoint.put_writes(saver, first_config, [{"step", 1}], "task-1")

    assert {:ok, second_config} =
             Checkpoint.put(
               saver,
               first_config,
               %{"id" => "cp-2", "channel_values" => %{step: 2}},
               %{source: "loop"},
               %{step: 2}
             )

    assert [%{checkpoint: %{"id" => "cp-2"}, parent_config: nil}] =
             Checkpoint.list(saver, config)

    refute Checkpoint.get_tuple(saver, first_config)

    assert %{checkpoint: %{"id" => "cp-2"}, pending_writes: []} =
             Checkpoint.get_tuple(saver, second_config)
  end

  test "shallow saver works through Task-backed checkpoint facade calls" do
    saver = new_saver(shallow?: true)
    config = %{"configurable" => %{"thread_id" => "shallow-async-thread"}}

    assert {:ok, first_config} =
             Checkpoint.async_put(
               saver,
               config,
               %{"id" => "cp-async-1", "channel_values" => %{step: 1}},
               %{source: "loop"},
               %{step: 1}
             )
             |> Async.await()

    assert {:ok, second_config} =
             Checkpoint.async_put(
               saver,
               first_config,
               %{"id" => "cp-async-2", "channel_values" => %{step: 2}},
               %{source: "loop"},
               %{step: 2}
             )
             |> Async.await()

    assert %{checkpoint: %{"id" => "cp-async-2"}, parent_config: nil} =
             Checkpoint.async_get_tuple(saver, second_config)
             |> Async.await()

    assert [latest] = Checkpoint.async_list(saver, config) |> Async.await()
    assert latest.checkpoint["id"] == "cp-async-2"
  end

  defp new_saver(opts \\ []) do
    checkpoints = LivePostgres.unique_table("bw_ecto_checkpoints")
    writes = LivePostgres.unique_table("bw_ecto_writes")
    migration = [adapters: [{:checkpoint, checkpoints_table: checkpoints, writes_table: writes}]]
    version = LivePostgres.migrate(migration)

    on_exit(fn ->
      LivePostgres.drop_tables([writes, checkpoints])
      LivePostgres.clear_migration(version)
    end)

    opts
    |> Keyword.put(:repo, PostgresRepo)
    |> Keyword.put(:checkpoints_table, checkpoints)
    |> Keyword.put(:writes_table, writes)
    |> Ecto.new()
  end
end
