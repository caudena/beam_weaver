defmodule BeamWeaver.Checkpoint.UtilsTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Checkpoint.Utils

  test "empty_checkpoint produces saver-compatible checkpoint maps" do
    checkpoint = Utils.empty_checkpoint(id: "cp-empty", metadata: %{source: "input"})

    assert checkpoint["v"] == 1
    assert checkpoint["id"] == "cp-empty"
    assert checkpoint["channel_values"] == %{}
    assert checkpoint["channel_versions"] == %{}
    assert checkpoint["versions_seen"] == %{}
    assert checkpoint["pending_sends"] == []
    assert checkpoint["channel_deltas"] == %{}
    assert checkpoint["metadata"] == %{source: "input"}
  end

  test "from_channels builds checkpoint values and version maps without mutating channel state" do
    channels = %{messages: ["hello"], private: :secret}

    checkpoint =
      Utils.from_channels(channels,
        id: "cp-values",
        channel_versions: %{messages: 2},
        versions_seen: %{model: %{messages: 1}}
      )

    assert checkpoint["id"] == "cp-values"
    assert checkpoint["channel_values"] == %{"messages" => ["hello"], "private" => :secret}
    assert checkpoint["channel_versions"] == %{"messages" => 2}
    assert checkpoint["versions_seen"] == %{model: %{messages: 1}}
  end

  test "checkpoint_id extracts IDs from config, checkpoint maps, tuples, and nil safely" do
    assert Utils.checkpoint_id(%{"configurable" => %{"checkpoint_id" => "cp-config"}}) ==
             "cp-config"

    assert Utils.checkpoint_id(%{checkpoint: %{"id" => "cp-tuple"}}) == "cp-tuple"
    assert Utils.checkpoint_id(%{"id" => "cp-direct"}) == "cp-direct"
    assert Utils.checkpoint_id(nil) == nil
  end

  test "metadata extracts metadata from tuple/config/map shapes without raising" do
    assert Utils.metadata(%{metadata: %{source: "tuple"}}) == %{source: "tuple"}

    assert Utils.metadata(%{"metadata" => %{"source" => "checkpoint"}}) == %{
             "source" => "checkpoint"
           }

    assert Utils.metadata(%{
             "configurable" => %{"thread_id" => "thread"},
             "metadata" => %{run: "r"}
           }) ==
             %{run: "r"}

    assert Utils.metadata(nil) == %{}
  end
end
