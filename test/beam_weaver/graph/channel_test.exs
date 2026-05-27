defmodule BeamWeaver.Graph.ChannelTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Checkpoint
  alias BeamWeaver.Checkpoint.ETS, as: CheckpointETS
  alias BeamWeaver.Graph.Channel
  alias BeamWeaver.Graph.Channels.AnyValue
  alias BeamWeaver.Graph.Channels.BinaryOperatorAggregate
  alias BeamWeaver.Graph.Channels.DeltaChannel
  alias BeamWeaver.Graph.Channels.EphemeralValue
  alias BeamWeaver.Graph.Channels.LastValue
  alias BeamWeaver.Graph.Channels.LastValueAfterFinish
  alias BeamWeaver.Graph.Channels.NamedBarrierValue
  alias BeamWeaver.Graph.Channels.NamedBarrierValueAfterFinish
  alias BeamWeaver.Graph.Channels.Topic
  alias BeamWeaver.Graph.Channels.UntrackedValue
  alias BeamWeaver.Graph.Execution.ChannelVersion
  alias BeamWeaver.Graph.Overwrite

  defmodule VersionedChannel do
    use BeamWeaver.Graph.Channel

    defstruct [:key, value: nil]

    def new(opts \\ []), do: %__MODULE__{key: Keyword.get(opts, :key)}
    def update(channel, [value]), do: {:ok, %{channel | value: value}, true}
    def update(channel, []), do: {:ok, channel, false}
    def get(%{value: nil, key: key}), do: {:error, BeamWeaver.Graph.Channel.empty_error(key)}
    def get(%{value: value}), do: {:ok, value}
    def checkpoint(%{value: nil}), do: BeamWeaver.Graph.Channel.missing()
    def checkpoint(%{value: value}), do: value
    def from_checkpoint(channel, checkpoint), do: %{channel | value: checkpoint}
    def copy(channel), do: struct(__MODULE__, Map.from_struct(channel))
    def available?(%{value: value}), do: not is_nil(value)
    def null_version(_channel), do: "zero"
    def version_equal?(_channel, left, right), do: to_string(left) == to_string(right)
  end

  defmodule DefaultedChannel do
    use BeamWeaver.Graph.Channel

    defstruct [:key, type: :custom, value: nil]

    def new(opts \\ []), do: %__MODULE__{key: Keyword.get(opts, :key)}
    def update(channel, [value]), do: {:ok, %{channel | value: value}, true}
    def update(channel, []), do: {:ok, channel, false}
    def get(%{value: nil, key: key}), do: {:error, Channel.empty_error(key)}
    def get(%{value: value}), do: {:ok, value}
    def checkpoint(%{value: value}), do: value || Channel.missing()
    def from_checkpoint(channel, checkpoint), do: %{channel | value: checkpoint}
    def available?(%{value: value}), do: not is_nil(value)
  end

  test "last value stores exactly one update per step and restores checkpoints" do
    channel = LastValue.new(key: "input", type: :integer)
    assert Channel.value_type(channel) == :integer
    assert Channel.update_type(channel) == :integer
    assert Channel.available?(channel) == false
    assert Channel.checkpoint(channel) == Channel.missing()
    assert Channel.get(channel) == {:error, Channel.empty_error("input")}
    assert {:ok, ^channel, false} = Channel.update(channel, [])

    assert {:error, %{type: :invalid_update}} = Channel.update(channel, [1, 2])
    assert {:ok, channel, true} = Channel.update(channel, [3])
    assert Channel.get(channel) == {:ok, 3}
    assert Channel.available?(channel)

    assert {:ok, channel, true} = Channel.update(channel, [4])
    assert Channel.get(channel) == {:ok, 4}

    copied = Channel.copy(channel)
    assert Channel.get(copied) == {:ok, 4}

    assert {:ok, copied, true} = Channel.update(copied, [5])
    assert Channel.get(copied) == {:ok, 5}
    assert Channel.get(channel) == {:ok, 4}

    restored = Channel.from_checkpoint(LastValue.new(key: "input"), Channel.checkpoint(channel))
    assert Channel.get(restored) == {:ok, 4}

    empty = Channel.from_checkpoint(LastValue.new(key: "input"), Channel.missing())
    assert {:error, %{type: :empty_channel}} = Channel.get(empty)
  end

  test "channel version comparison uses channel-specific null and equality policy" do
    graph =
      BeamWeaver.Graph.new(state_schema: %{custom: BeamWeaver.Graph.channel(VersionedChannel)})

    refute ChannelVersion.changed?(%{}, %{"custom" => :zero}, "custom", graph)
    assert ChannelVersion.changed?(%{}, %{"custom" => "one"}, "custom", graph)
  end

  test "use BeamWeaver.Graph.Channel supplies default optional callbacks" do
    channel = DefaultedChannel.new(key: "defaulted")

    assert BeamWeaver.Graph.Channel.Dispatch.impl_for(channel)
    assert Channel.value_type(channel) == :custom
    assert Channel.update_type(channel) == :custom
    assert Channel.null_version(channel) == nil
    assert Channel.version_equal?(channel, 1, 1)
    assert {:ok, ^channel, false} = Channel.consume(channel)
    assert {:ok, ^channel, false} = Channel.finish(channel)

    assert {:ok, channel, true} = Channel.update(channel, ["value"])
    assert Channel.get(Channel.copy(channel)) == {:ok, "value"}
  end

  test "topic clears per step unless accumulate is enabled" do
    channel = Topic.new()

    assert {:ok, channel, true} = Channel.update(channel, ["a", "b"])
    assert Channel.get(channel) == {:ok, ["a", "b"]}

    assert {:ok, channel, true} = Channel.update(channel, [["c", "d"], "d"])
    assert Channel.get(channel) == {:ok, ["c", "d", "d"]}

    assert {:ok, channel, true} = Channel.update(channel, [])
    assert {:error, %{type: :empty_channel}} = Channel.get(channel)

    channel = Topic.new(accumulate: true)
    assert {:ok, channel, true} = Channel.update(channel, ["a", "b"])
    assert {:ok, channel, true} = Channel.update(channel, [["c"], "d"])
    assert Channel.get(channel) == {:ok, ["a", "b", "c", "d"]}
    assert {:ok, _channel, false} = Channel.update(channel, [])
  end

  test "binary aggregate folds updates and supports one overwrite" do
    channel = BinaryOperatorAggregate.new(&Kernel.+/2, initial: 0, key: "total")

    assert Channel.get(channel) == {:ok, 0}
    assert {:ok, channel, true} = Channel.update(channel, [1, 2, 3])
    assert Channel.get(channel) == {:ok, 6}

    # Upstream: langgraph/tests/test_channels.py::test_binop and
    # langgraph/channels/binop.py. Values after an overwrite in the same
    # superstep are ignored.
    assert {:ok, channel, true} = Channel.update(channel, [%Overwrite{value: 10}, 5])
    assert Channel.get(channel) == {:ok, 10}

    assert {:ok, channel, true} = Channel.update(channel, [%{"__overwrite__" => 12}, 5])
    assert Channel.get(channel) == {:ok, 12}

    assert {:error, %{type: :invalid_update}} =
             Channel.update(channel, [%Overwrite{value: 1}, %Overwrite{value: 2}])
  end

  test "any value clears on empty update after being available" do
    channel = AnyValue.new()

    assert {:ok, channel, true} = Channel.update(channel, ["same", "same"])
    assert Channel.get(channel) == {:ok, "same"}
    assert {:ok, channel, true} = Channel.update(channel, [])
    assert {:error, %{type: :empty_channel}} = Channel.get(channel)
    assert {:ok, _channel, false} = Channel.update(channel, [])
  end

  test "ephemeral values clear on the next empty update and can be guarded" do
    channel = EphemeralValue.new(key: "step")

    assert {:error, %{type: :invalid_update}} = Channel.update(channel, [1, 2])
    assert {:ok, channel, true} = Channel.update(channel, [1])
    assert Channel.get(channel) == {:ok, 1}
    assert {:ok, channel, true} = Channel.update(channel, [])
    assert {:error, %{type: :empty_channel}} = Channel.get(channel)

    unguarded = EphemeralValue.new(guard: false)
    assert {:ok, unguarded, true} = Channel.update(unguarded, [1, 2])
    assert Channel.get(unguarded) == {:ok, 2}
  end

  test "untracked values never checkpoint" do
    channel = UntrackedValue.new()

    assert {:ok, channel, true} = Channel.update(channel, [%{session: "tmp"}])
    assert Channel.get(channel) == {:ok, %{session: "tmp"}}
    assert Channel.checkpoint(channel) == Channel.missing()

    restored = Channel.from_checkpoint(UntrackedValue.new(), Channel.checkpoint(channel))
    assert {:error, %{type: :empty_channel}} = Channel.get(restored)
  end

  test "last value after finish becomes readable only after finish and clears on consume" do
    channel = LastValueAfterFinish.new(key: "done", type: :string)
    assert Channel.value_type(channel) == :string
    assert Channel.update_type(channel) == :string
    assert Channel.checkpoint(channel) == Channel.missing()
    assert {:ok, ^channel, false} = Channel.update(channel, [])
    assert {:ok, ^channel, false} = Channel.finish(channel)

    assert {:ok, channel, true} = Channel.update(channel, ["answer"])
    assert {:error, %{type: :empty_channel}} = Channel.get(channel)
    refute Channel.available?(channel)

    assert {:ok, channel, true} = Channel.finish(channel)
    assert Channel.get(channel) == {:ok, "answer"}
    assert Channel.available?(channel)
    assert {:ok, ^channel, false} = Channel.finish(channel)

    checkpoint = Channel.checkpoint(channel)
    restored = Channel.from_checkpoint(LastValueAfterFinish.new(key: "done"), checkpoint)
    assert Channel.get(restored) == {:ok, "answer"}

    assert {:ok, reset, true} = Channel.update(restored, ["next"])
    assert {:error, %{type: :empty_channel}} = Channel.get(reset)
    assert Channel.checkpoint(reset) == {"next", false}

    assert {:ok, channel, true} = Channel.consume(channel)
    assert {:error, %{type: :empty_channel}} = Channel.get(channel)
    assert Channel.checkpoint(channel) == Channel.missing()
    assert {:ok, ^channel, false} = Channel.consume(channel)
  end

  test "named barriers become available only after all names are seen" do
    channel = NamedBarrierValue.new(["a", "b"], key: "join")

    assert {:ok, channel, true} = Channel.update(channel, ["a"])
    assert {:ok, ^channel, false} = Channel.update(channel, ["a"])
    assert {:error, %{type: :empty_channel}} = Channel.get(channel)
    assert Channel.checkpoint(channel) == ["a"]

    copied = Channel.copy(channel)
    assert {:ok, copied, true} = Channel.update(copied, ["b"])
    assert Channel.get(copied) == {:ok, nil}
    assert {:error, %{type: :empty_channel}} = Channel.get(channel)

    restored =
      NamedBarrierValue.new(["a", "b"], key: "join")
      |> Channel.from_checkpoint(Channel.checkpoint(copied))

    assert Channel.get(restored) == {:ok, nil}

    assert {:ok, channel, true} = Channel.update(channel, ["b"])
    assert Channel.get(channel) == {:ok, nil}

    assert {:ok, channel, true} = Channel.consume(channel)
    assert {:error, %{type: :empty_channel}} = Channel.get(channel)
    assert {:ok, ^channel, false} = Channel.consume(channel)
    assert {:error, %{type: :invalid_update}} = Channel.update(channel, ["c"])
  end

  test "named barriers after finish wait for all names and finish" do
    channel = NamedBarrierValueAfterFinish.new(["a", "b"])

    assert {:ok, channel, true} = Channel.update(channel, ["a", "b"])
    assert {:error, %{type: :empty_channel}} = Channel.get(channel)

    assert {:ok, channel, true} = Channel.finish(channel)
    assert Channel.get(channel) == {:ok, nil}
    assert {:ok, ^channel, false} = Channel.finish(channel)

    checkpoint = Channel.checkpoint(channel)

    restored =
      NamedBarrierValueAfterFinish.new(["a", "b"])
      |> Channel.from_checkpoint(checkpoint)

    assert Channel.get(restored) == {:ok, nil}

    copied = Channel.copy(restored)
    assert {:ok, copied, true} = Channel.consume(copied)
    assert {:error, %{type: :empty_channel}} = Channel.get(copied)
    assert Channel.get(restored) == {:ok, nil}
  end

  test "delta channel applies reducer batches, overwrite, replay, and missing checkpoints" do
    reducer = fn state, writes -> state ++ writes end
    channel = DeltaChannel.new(reducer, initial: [])

    assert {:ok, channel, true} = Channel.update(channel, ["a"])
    assert {:ok, channel, true} = Channel.update(channel, ["b", "c"])
    assert Channel.get(channel) == {:ok, ["a", "b", "c"]}
    assert Channel.checkpoint(channel) == Channel.missing()

    assert {:ok, channel, true} = Channel.update(channel, [%Overwrite{value: ["x"]}, "y"])
    assert Channel.get(channel) == {:ok, ["x", "y"]}

    assert {:ok, channel, true} =
             Channel.update(channel, ["before", %{"__overwrite__" => ["z"]}, "after"])

    assert Channel.get(channel) == {:ok, ["z", "before", "after"]}

    restored = Channel.from_checkpoint(DeltaChannel.new(reducer, initial: []), Channel.missing())

    assert {:ok, restored, true} =
             DeltaChannel.replay_writes(restored, [
               {"task-1", "messages", "one"},
               {"task-2", "messages", "two"}
             ])

    assert Channel.get(restored) == {:ok, ["one", "two"]}
  end

  test "delta channel preserves non-list seeds and replays map reducer writes" do
    # Upstream: langgraph/tests/test_channels.py dict reducer and seed cases.
    merge_maps = fn state, writes ->
      Enum.reduce(writes, state, fn write, acc -> Map.merge(acc, write) end)
    end

    channel = DeltaChannel.new(merge_maps, key: "files", initial: %{})
    assert Channel.available?(Channel.from_checkpoint(channel, Channel.missing()))
    assert Channel.get(Channel.from_checkpoint(channel, Channel.missing())) == {:ok, %{}}

    assert {:ok, channel, true} = Channel.update(channel, [%{"a" => 1}])
    assert {:ok, channel, true} = Channel.update(channel, [%{"b" => 2}])
    assert Channel.get(channel) == {:ok, %{"a" => 1, "b" => 2}}
    assert Channel.checkpoint(channel) == Channel.missing()

    restored =
      Channel.from_checkpoint(DeltaChannel.new(merge_maps, key: "files", initial: %{}), %{
        "seed" => true
      })

    assert Channel.get(restored) == {:ok, %{"seed" => true}}

    assert {:ok, replayed, true} =
             DeltaChannel.replay_writes(
               Channel.from_checkpoint(
                 DeltaChannel.new(merge_maps, key: "files", initial: %{}),
                 %{}
               ),
               [
                 {"t0", "files", %{"a" => 1}},
                 {"t1", "files", %{"b" => 2}},
                 {"t2", "files", %BeamWeaver.Graph.Overwrite{value: %{"x" => 10}}},
                 {"t3", "files", %{"z" => 30}}
               ]
             )

    assert Channel.get(replayed) == {:ok, %{"x" => 10, "z" => 30}}
  end

  test "delta channel map reducers support deletion semantics and nil seeds" do
    # Upstream: langgraph/tests/test_channels.py deletion and seed-none cases.
    merge_files = fn state, writes ->
      Enum.reduce(writes, state, fn write, acc ->
        Enum.reduce(write, acc, fn
          {path, nil}, files -> Map.delete(files, path)
          {path, content}, files -> Map.put(files, path, content)
        end)
      end)
    end

    assert {:ok, channel, true} =
             DeltaChannel.new(merge_files, key: "files", initial: %{})
             |> Channel.update([%{"file1.py" => "content1", "file2.py" => "content2"}])

    assert {:ok, channel, true} =
             Channel.update(channel, [%{"file1.py" => nil, "file3.py" => "content3"}])

    assert Channel.get(channel) == {:ok, %{"file2.py" => "content2", "file3.py" => "content3"}}

    replace = fn state, writes -> List.last(writes) || state end

    nil_seed =
      DeltaChannel.new(replace, key: "x", initial: [])
      |> Channel.from_checkpoint(nil)

    assert Channel.get(nil_seed) == {:ok, nil}

    assert {:ok, replayed, true} = DeltaChannel.replay_writes(nil_seed, [{"t0", "x", "after"}])
    assert Channel.get(replayed) == {:ok, "after"}
  end

  test "delta channel replays saver pending-write history for its channel" do
    saver = CheckpointETS.new()
    reducer = fn existing, updates -> existing ++ List.wrap(updates) end
    channel = DeltaChannel.new(reducer, key: "items", initial: [])

    {:ok, first} =
      Checkpoint.put(
        saver,
        %{"configurable" => %{"thread_id" => "delta-history"}},
        checkpoint("00000000000000000001"),
        %{step: 0},
        %{}
      )

    assert :ok =
             Checkpoint.put_writes(saver, first, [{"items", "a"}, {"other", "skip"}], "task-a")

    {:ok, second} =
      Checkpoint.put(
        saver,
        first,
        checkpoint("00000000000000000002"),
        %{step: 1},
        %{}
      )

    assert :ok = Checkpoint.put_writes(saver, second, [{"items", "b"}], "task-b")

    assert {:ok, replayed, true} = DeltaChannel.replay_history(channel, saver, second)
    assert Channel.get(replayed) == {:ok, ["a", "b"]}
  end

  defp checkpoint(id) do
    %{
      "id" => id,
      "channel_values" => %{},
      "channel_versions" => %{},
      "versions_seen" => %{},
      "updated_channels" => []
    }
  end
end
