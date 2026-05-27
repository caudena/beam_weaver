defmodule BeamWeaver.Checkpoint.EctoTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Checkpoint
  alias BeamWeaver.Checkpoint.Ecto
  alias BeamWeaver.Checkpoint.FakeSQL
  alias BeamWeaver.Core.Async

  test "uses the saver contract through an Ecto/Postgres query boundary" do
    {:ok, repo} = FakeSQL.start_link()
    saver = Ecto.new(repo: repo, query_module: FakeSQL)
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
             checkpoint: %{"channel_values" => %{step: 1}},
             pending_writes: pending_writes,
             pending_write_paths: pending_write_paths
           } =
             Checkpoint.get_tuple(saver, config)

    assert pending_writes == [{"task-1", "step", 1}]
    assert pending_write_paths == [{"task-1", "step", "node:step"}]
    assert [%{checkpoint: %{"channel_values" => %{step: 1}}}] = Checkpoint.list(saver, config)
  end

  test "supports shallow saver semantics through the same checkpoint facade" do
    {:ok, repo} = FakeSQL.start_link()
    saver = Ecto.new(repo: repo, query_module: FakeSQL, shallow?: true)
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
    {:ok, repo} = FakeSQL.start_link()
    saver = Ecto.new(repo: repo, query_module: FakeSQL, shallow?: true)
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
end
