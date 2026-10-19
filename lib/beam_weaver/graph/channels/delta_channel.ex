defmodule BeamWeaver.Graph.Channels.DeltaChannel do
  @moduledoc """
  Reducer channel that checkpoints as missing and can replay pending writes.

  Instead of storing its full value in every checkpoint, the channel rebuilds it
  by replaying recorded writes (see `replay_writes/2`); a full snapshot is
  saved every `:snapshot_frequency` updates (default 1000). This module is the
  in-memory channel; reading the write history from checkpoint savers is
  handled by the checkpoint layer.

  A `BeamWeaver.Graph.Overwrite` replaces the value and drops the other writes
  of its step, so the step is saved as that overwrite alone.

  Options:

    * `:initial` - the value before any write (default `[]`).
    * `:snapshot_frequency` - updates between full snapshots (default 1000).
    * `:prepare` - a function that prepares each write before it is applied,
      streamed or saved, so every read of the history replays the same
      write. A prepared write can go through it again and must come back
      unchanged. `BeamWeaver.Graph.Messages.delta_channel/1` uses it to turn
      writes into messages with ids.
  """

  use BeamWeaver.Graph.Channel

  alias BeamWeaver.Checkpoint.PendingWrite
  alias BeamWeaver.Graph.Channel
  alias BeamWeaver.Graph.Channels.DeltaSnapshot
  alias BeamWeaver.Graph.Overwrite

  # The task id under which a checkpoint's delta history returns the writes
  # of the step that checkpoint holds.
  @step_task "__delta_checkpoint__"

  defstruct [:key, :reducer, :prepare, initial: [], value: Channel.missing(), snapshot_frequency: 1000]

  def new(reducer, opts \\ []) when is_function(reducer, 2) do
    snapshot_frequency = Keyword.get(opts, :snapshot_frequency, 1000)
    prepare = Keyword.get(opts, :prepare)

    if not (is_integer(snapshot_frequency) and snapshot_frequency > 0) do
      raise ArgumentError, "snapshot_frequency must be a positive integer"
    end

    if not (is_nil(prepare) or is_function(prepare, 1)) do
      raise ArgumentError, "prepare must be a function of one argument"
    end

    %__MODULE__{
      key: Keyword.get(opts, :key),
      reducer: reducer,
      prepare: prepare,
      initial: Keyword.get(opts, :initial, []),
      snapshot_frequency: snapshot_frequency
    }
  end

  @impl true
  def update(channel, []), do: {:ok, channel, false}

  def update(channel, updates) do
    case overwrites(updates) do
      [_first, _second | _rest] ->
        {:error,
         Channel.invalid_update("delta channel can receive only one overwrite per step", %{channel: channel.key})}

      overwrites ->
        {:ok, apply_step(channel, updates, overwrites), true}
    end
  rescue
    exception -> {:error, Channel.invalid_update(Exception.message(exception), %{channel: channel.key})}
  end

  @impl true
  def checkpoint(_channel), do: Channel.missing()

  @impl true
  def from_checkpoint(channel, checkpoint) do
    if checkpoint == Channel.missing(),
      do: %{channel | value: channel.initial},
      else: %{channel | value: DeltaSnapshot.unwrap(checkpoint)}
  end

  @doc false
  @spec prepare(%__MODULE__{}, [term()]) :: [term()]
  def prepare(%__MODULE__{prepare: nil}, writes), do: writes
  def prepare(%__MODULE__{prepare: prepare}, writes), do: Enum.map(writes, prepare)

  @doc """
  Applies saved writes on top of the channel's value.

  The writes a checkpoint holds for its step, and the pending writes saved on
  a checkpoint, each count as the writes of one step, as when they were made:
  an overwrite among them drops the others. Writes given as
  `{task_id, channel, value}` tuples count as one step.
  """
  def replay_writes(channel, pending_writes) do
    case steps(pending_writes) do
      [] -> {:ok, channel, false}
      steps -> {:ok, replay_steps(channel, steps), true}
    end
  end

  # Only the steps since the last overwrite count. The reducer folds their
  # writes in one call, as it would one step after another, so a long
  # history replays in one pass.
  defp replay_steps(channel, steps) do
    {channel, later} =
      Enum.reduce(steps, {channel, []}, fn step, {channel, later} ->
        case overwrites(step) do
          [] -> {channel, [step | later]}
          overwrites -> {%{channel | value: List.last(overwrites)}, []}
        end
      end)

    case later do
      [] -> channel
      later -> apply_step(channel, later |> Enum.reverse() |> Enum.concat(), [])
    end
  end

  @doc false
  # The writes a step keeps: an overwrite drops the others.
  @spec kept_writes([term()]) :: [term()]
  def kept_writes(writes) do
    case overwrites(writes) do
      [] -> writes
      overwrites -> [Overwrite.new(List.last(overwrites))]
    end
  end

  @doc false
  # The values of saved writes, grouped by the step they belong to.
  @spec steps(list()) :: [[term()]]
  def steps(pending_writes) do
    pending_writes
    |> Enum.flat_map(fn
      %PendingWrite{} = write -> [{{write.checkpoint_id, write.task_id == @step_task}, write.value}]
      {_task_id, _channel, value} -> [{nil, value}]
      {_task_id, _channel, value, _path} -> [{nil, value}]
      _other -> []
    end)
    |> Enum.chunk_by(&elem(&1, 0))
    |> Enum.map(fn writes -> Enum.map(writes, &elem(&1, 1)) end)
  end

  @doc false
  def step_task, do: @step_task

  defp current_value(%__MODULE__{value: value, initial: initial}) do
    if value == Channel.missing(), do: initial, else: value
  end

  defp apply_step(channel, updates, []), do: %{channel | value: channel.reducer.(current_value(channel), updates)}
  defp apply_step(channel, _updates, overwrites), do: %{channel | value: List.last(overwrites)}

  defp overwrites(updates) do
    for update <- updates, {:ok, value} <- [Overwrite.get(update)], do: value
  end
end
