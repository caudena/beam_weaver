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

  test "batches pending write reads for checkpoint and parent task writes" do
    saver = new_saver()
    config = %{"configurable" => %{"thread_id" => "ecto-batched-get-tuple"}}

    assert {:ok, parent_config} =
             Checkpoint.put(
               saver,
               config,
               %{"id" => "cp-parent", "channel_values" => %{"step" => 1}},
               %{source: "loop"},
               %{"step" => 1}
             )

    assert :ok =
             Checkpoint.put_writes(
               saver,
               parent_config,
               [{"__tasks__", %{"node" => "resume-me"}}],
               "task-parent"
             )

    assert {:ok, child_config} =
             Checkpoint.put(
               saver,
               parent_config,
               %{"id" => "cp-child", "channel_values" => %{"step" => 2}},
               %{source: "loop"},
               %{"step" => 2}
             )

    assert :ok = Checkpoint.put_writes(saver, child_config, [{"step", 2}], "task-child")

    attach_query_counter()

    assert %{
             checkpoint: %{
               "channel_values" => %{
                 "__tasks__" => [%{"node" => "resume-me"}],
                 "step" => 2
               }
             },
             pending_writes: [{"task-child", "step", 2}]
           } = Checkpoint.get_tuple(saver, child_config)

    queries = drain_queries()

    assert length(queries) == 1
    assert Enum.any?(queries, fn {sql, _params} -> String.contains?(sql, "LEFT OUTER JOIN") end)
    refute Enum.any?(queries, fn {_sql, params} -> params == ["ecto-batched-get-tuple", "", "cp-parent"] end)
  end

  test "batches pending write reads when listing checkpoint history" do
    saver = new_saver()
    config = %{"configurable" => %{"thread_id" => "ecto-batched-list"}}

    stored =
      Enum.reduce(1..3, config, fn step, previous_config ->
        {:ok, next_config} =
          Checkpoint.put(
            saver,
            previous_config,
            %{"id" => "cp-#{step}", "channel_values" => %{"step" => step}},
            %{source: "loop", step: step},
            %{"step" => step}
          )

        :ok = Checkpoint.put_writes(saver, next_config, [{"step", step}], "task-#{step}")
        next_config
      end)

    attach_query_counter()

    assert Checkpoint.list(saver, config)
           |> Enum.map(& &1.checkpoint["id"]) == ["cp-3", "cp-2", "cp-1"]

    assert stored["configurable"]["checkpoint_id"] == "cp-3"

    queries = drain_queries()

    assert length(queries) == 1
    assert Enum.any?(queries, fn {sql, _params} -> String.contains?(sql, "LEFT OUTER JOIN") end)
  end

  test "atomically batches, orders, and forks explicit checkpoint ids" do
    saver = new_saver()
    thread = "ecto-ordered-batch"
    base = %{"configurable" => %{"thread_id" => thread}}

    entries = [
      checkpoint_entry(base, "z", nil, 1),
      checkpoint_entry(base, "a", "z", 2)
    ]

    assert {:ok, [_root, child]} = Checkpoint.put_many(saver, entries)
    assert {:ok, %{checkpoint: %{"id" => "a"}}} = Checkpoint.fetch_tuple(saver, base)

    assert {:ok, listed} = Checkpoint.list_result(saver, base)
    assert Enum.map(listed, & &1.checkpoint["id"]) == ["a", "z"]

    assert {:ok, forked} = Checkpoint.fork_at(saver, child, "ecto-forked")
    assert forked["configurable"]["checkpoint_id"] == "a"

    invalid = %{checkpoint_entry(base, "broken", "a", 3) | writes: [:invalid]}

    assert {:error, _reason} =
             Checkpoint.put_many(saver, [checkpoint_entry(base, "next", "a", 3), invalid])

    next = put_in(base, ["configurable", "checkpoint_id"], "next")
    assert {:ok, nil} = Checkpoint.fetch_tuple(saver, next)
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

  defp checkpoint_entry(base, id, parent_id, value) do
    config =
      if parent_id,
        do: put_in(base, ["configurable", "checkpoint_id"], parent_id),
        else: base

    %{
      config: config,
      checkpoint: %{
        "id" => id,
        "channel_values" => %{"value" => value},
        "channel_versions" => %{"value" => value}
      },
      metadata: %{},
      versions: %{"value" => value},
      writes: [{"task", "value", value}]
    }
  end

  defp drain_queries(acc \\ []) do
    receive do
      {:ecto_query, sql, params} -> drain_queries([{sql, params} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp attach_query_counter do
    handler = {__MODULE__, self(), make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:beam_weaver, :test, :postgres_repo, :query],
        &__MODULE__.handle_query/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  @doc false
  def handle_query(_event, _measurements, metadata, pid) do
    send(pid, {:ecto_query, metadata.query, metadata.params})
  end
end
