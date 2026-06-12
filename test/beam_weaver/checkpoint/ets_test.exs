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
