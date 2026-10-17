defmodule BeamWeaver.Checkpoint.DeltaHistory do
  @moduledoc false

  alias BeamWeaver.Checkpoint
  alias BeamWeaver.Checkpoint.PendingWrite
  alias BeamWeaver.Graph.Channel
  alias BeamWeaver.Graph.Channels.DeltaChannel
  alias BeamWeaver.Graph.Channels.DeltaSnapshot
  alias BeamWeaver.MapAccess

  @max_read_ahead 256

  # Reads the checkpoint `config` names and its parents, newest first, once
  # for all the channels. A channel's history stops at the nearest checkpoint
  # that stores its value, a snapshot or a plain value, which is its seed; the
  # read stops when every channel's has. The target's own pending writes are
  # left out: they belong to the step after it.
  #
  # With `read_ahead: n`, the parents are listed n at a time, then twice as
  # many each time up to 256, so a long history takes a few
  # reads instead of one per checkpoint; a saver whose every read is a round
  # trip passes it. A parent the listing doesn't hold, as on a branch whose
  # older siblings came in between, is read on its own.
  @spec get(struct(), map(), [String.t()], keyword()) :: map()
  def get(saver, config, channel_names, opts) do
    channels = channel_names |> Enum.map(&to_string/1) |> Enum.uniq()
    history = Map.new(channels, &{&1, %{seed: Channel.missing(), writes: []}})
    reader = %{saver: saver, read_ahead: Keyword.get(opts, :read_ahead), read: %{}}

    case channels != [] and Checkpoint.get_tuple(saver, config) do
      %{} = tuple -> walk(reader, tuple, channels, history, MapSet.new(), false)
      _none -> history
    end
  end

  # A parent that was already read ends the read: a checkpoint saved again
  # under one of its descendants would otherwise make it go round forever.
  defp walk(reader, tuple, open, history, seen, pending?) do
    {open, history} =
      Enum.reduce(open, {[], history}, fn channel, {open, history} ->
        pending = if pending?, do: pending_writes(tuple, channel), else: []
        later = history[channel].writes

        case stored_value(tuple, channel) do
          {:ok, seed} -> {open, Map.put(history, channel, %{seed: seed, writes: pending ++ later})}
          :error -> {[channel | open], put_in(history[channel].writes, step_writes(tuple, channel) ++ pending ++ later)}
        end
      end)

    seen = MapSet.put(seen, checkpoint_id(tuple))

    with [_ | _] <- open,
         %{} = parent_config <- tuple.parent_config,
         false <- MapSet.member?(seen, config_checkpoint_id(parent_config)),
         {%{} = parent, reader} <- read_parent(reader, tuple, parent_config) do
      walk(reader, parent, Enum.reverse(open), history, seen, true)
    else
      _done -> history
    end
  end

  defp read_parent(reader, tuple, parent_config) do
    id = config_checkpoint_id(parent_config)

    with :error <- take_read(reader, id),
         reader = read_ahead(reader, tuple),
         :error <- take_read(reader, id) do
      {Checkpoint.get_tuple(reader.saver, parent_config), reader}
    end
  end

  defp take_read(reader, id) do
    case Map.pop(reader.read, id) do
      {nil, _read} -> :error
      {parent, read} -> {parent, %{reader | read: read}}
    end
  end

  defp read_ahead(%{read_ahead: nil} = reader, _tuple), do: reader

  defp read_ahead(reader, tuple) do
    owner = %{"configurable" => Map.take(tuple.config["configurable"], ["thread_id", "checkpoint_ns"])}

    case Checkpoint.list_result(reader.saver, owner, before: tuple.config, limit: reader.read_ahead) do
      {:ok, tuples} ->
        read = Map.merge(reader.read, Map.new(tuples, &{checkpoint_id(&1), &1}))
        %{reader | read: read, read_ahead: min(reader.read_ahead * 2, @max_read_ahead)}

      {:error, _reason} ->
        %{reader | read_ahead: nil}
    end
  end

  # The value a checkpoint stores for a channel, a snapshot's unwrapped.
  @spec stored_value(map(), String.t()) :: {:ok, term()} | :error
  def stored_value(tuple, channel), do: stored_in(tuple.checkpoint["channel_values"], channel)

  # The value a checkpoint's `values` store for a channel, a snapshot's
  # unwrapped.
  @spec stored_in(map(), String.t() | atom()) :: {:ok, term()} | :error
  def stored_in(values, channel) do
    missing = Channel.missing()

    case MapAccess.fetch(values, channel) do
      {:ok, value} when value != missing -> {:ok, DeltaSnapshot.unwrap(value)}
      _missing -> :error
    end
  end

  # The writes of the step a checkpoint holds, for one channel.
  @spec step_writes(map(), String.t()) :: [PendingWrite.t()]
  def step_writes(tuple, channel) do
    configurable = tuple.config["configurable"]

    tuple.checkpoint
    |> Map.get("channel_deltas", %{})
    |> Map.get(channel, [])
    |> Enum.with_index(fn value, index ->
      %PendingWrite{
        thread_id: configurable["thread_id"],
        checkpoint_ns: configurable["checkpoint_ns"],
        checkpoint_id: configurable["checkpoint_id"],
        task_id: DeltaChannel.step_task(),
        index: index,
        channel: channel,
        value: value,
        path: ""
      }
    end)
  end

  # The pending writes saved on a checkpoint, for one channel.
  @spec pending_writes(map(), String.t()) :: [PendingWrite.t()]
  def pending_writes(tuple, channel),
    do: tuple |> Map.get(:pending_write_records, []) |> Enum.filter(&(to_string(&1.channel) == channel))

  defp checkpoint_id(tuple), do: config_checkpoint_id(tuple.config)
  defp config_checkpoint_id(config), do: config["configurable"]["checkpoint_id"]
end
