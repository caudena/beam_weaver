defmodule BeamWeaver.Checkpoint.ETSTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Checkpoint
  alias BeamWeaver.Checkpoint.ETS

  test "persists checkpoint history by thread and retrieves the latest state" do
    saver = ETS.new()
    base_config = %{"configurable" => %{"thread_id" => "thread-1"}}

    assert {:ok, first_config} =
             Checkpoint.put(
               saver,
               base_config,
               %{"channel_values" => %{count: 1}},
               %{source: "input"},
               %{count: 1}
             )

    assert {:ok, second_config} =
             Checkpoint.put(
               saver,
               first_config,
               %{"channel_values" => %{count: 2}},
               %{source: "loop"},
               %{count: 2}
             )

    assert %{checkpoint: %{"channel_values" => %{count: 2}}} =
             Checkpoint.get_tuple(saver, base_config)

    assert %{checkpoint: %{"channel_values" => %{count: 1}}} =
             Checkpoint.get_tuple(saver, first_config)

    history = Checkpoint.list(saver, base_config)
    assert Enum.map(history, & &1.checkpoint["channel_values"].count) == [2, 1]

    assert second_config["configurable"]["checkpoint_id"] >
             first_config["configurable"]["checkpoint_id"]
  end

  test "a thread's tuples and history hold only its own checkpoints and pending writes" do
    saver = ETS.new()

    for thread_id <- ["thread-a", "thread-b"] do
      config = %{"configurable" => %{"thread_id" => thread_id}}
      {:ok, first} = Checkpoint.put(saver, config, %{"channel_values" => %{}}, %{source: "input"}, %{})
      assert :ok = Checkpoint.put_writes(saver, first, [{"__tasks__", "#{thread_id}-send"}], "task-1")
      {:ok, second} = Checkpoint.put(saver, first, %{"channel_values" => %{}}, %{source: "loop"}, %{})
      assert :ok = Checkpoint.put_writes(saver, second, [{"notes", "#{thread_id}-note"}], "task-2")
    end

    config = %{"configurable" => %{"thread_id" => "thread-a"}}

    assert %{checkpoint: checkpoint, pending_writes: [{"task-2", "notes", "thread-a-note"}]} =
             Checkpoint.get_tuple(saver, config)

    assert checkpoint["channel_values"]["__tasks__"] == ["thread-a-send"]

    assert [latest, first] = Checkpoint.list(saver, config)
    assert latest.pending_writes == [{"task-2", "notes", "thread-a-note"}]
    assert latest.checkpoint["channel_values"]["__tasks__"] == ["thread-a-send"]
    assert first.pending_writes == [{"task-1", "__tasks__", "thread-a-send"}]
  end

  test "stores pending writes and supports thread copy/delete" do
    saver = ETS.new()

    {:ok, config} =
      Checkpoint.put(
        saver,
        %{"configurable" => %{"thread_id" => "source"}},
        %{"channel_values" => %{answer: 41}},
        %{source: "loop"},
        %{answer: 1}
      )

    assert :ok = Checkpoint.put_writes(saver, config, [{"answer", 42}], "task-1", "node:answer")

    assert %{
             pending_writes: [{"task-1", "answer", 42}],
             pending_write_paths: [{"task-1", "answer", "node:answer"}]
           } =
             Checkpoint.get_tuple(saver, config)

    assert :ok = Checkpoint.copy_thread(saver, "source", "target")

    assert %{checkpoint: %{"channel_values" => %{answer: 41}}} =
             Checkpoint.get_tuple(saver, %{"configurable" => %{"thread_id" => "target"}})

    assert :ok = Checkpoint.delete_thread(saver, "source")
    assert Checkpoint.get_tuple(saver, %{"configurable" => %{"thread_id" => "source"}}) == nil
  end
end
