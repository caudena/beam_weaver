defmodule BeamWeaver.Graph.Channels.DeltaChannel do
  @moduledoc """
  Reducer channel that checkpoints as missing and can replay pending writes.

  This is the in-memory channel piece of LangGraph's beta DeltaChannel. Saver
  history integration is handled by the checkpoint delta-history helper.
  """

  use BeamWeaver.Graph.Channel

  alias BeamWeaver.Checkpoint
  alias BeamWeaver.Checkpoint.PendingWrite
  alias BeamWeaver.Graph.Channel
  alias BeamWeaver.Graph.Channels.DeltaSnapshot
  alias BeamWeaver.Graph.Overwrite

  defstruct [:key, :reducer, initial: [], value: Channel.missing(), snapshot_frequency: 1000]

  def new(reducer, opts \\ []) when is_function(reducer, 2) do
    snapshot_frequency = Keyword.get(opts, :snapshot_frequency, 1000)

    if not (is_integer(snapshot_frequency) and snapshot_frequency > 0) do
      raise ArgumentError, "snapshot_frequency must be a positive integer"
    end

    %__MODULE__{
      key: Keyword.get(opts, :key),
      reducer: reducer,
      initial: Keyword.get(opts, :initial, []),
      snapshot_frequency: snapshot_frequency
    }
  end

  @impl true
  def update(channel, []), do: {:ok, channel, false}

  def update(channel, updates) do
    case split_overwrite(channel, updates) do
      {:error, reason} ->
        {:error, Channel.invalid_update(reason, %{channel: channel.key})}

      {:ok, base, remaining} ->
        base = if base == :current, do: current_value(channel), else: base
        value = if remaining == [], do: base, else: channel.reducer.(base, remaining)
        {:ok, %{channel | value: value}, true}
    end
  end

  @impl true
  def get(%__MODULE__{value: value, key: key}) do
    if value == Channel.missing(), do: {:error, Channel.empty_error(key)}, else: {:ok, value}
  end

  @impl true
  def checkpoint(_channel), do: Channel.missing()

  @impl true
  def from_checkpoint(channel, checkpoint) do
    cond do
      checkpoint == Channel.missing() ->
        %{channel | value: channel.initial}

      match?(%DeltaSnapshot{}, checkpoint) ->
        %{channel | value: checkpoint.value}

      true ->
        %{channel | value: checkpoint}
    end
  end

  @impl true
  def available?(%__MODULE__{value: value}), do: value != Channel.missing()

  def replay_writes(channel, pending_writes) do
    values =
      Enum.flat_map(pending_writes, fn
        %PendingWrite{value: value} -> [value]
        {_task_id, _channel, value} -> [value]
        {_task_id, _channel, value, _path} -> [value]
        _other -> []
      end)

    {:ok, base, remaining} = replay_split(channel, values)
    base = if base == :current, do: current_value(channel), else: base
    value = if remaining == [], do: base, else: channel.reducer.(base, remaining)

    {:ok, %{channel | value: value}, values != []}
  end

  def replay_history(%__MODULE__{} = channel, saver, config, opts \\ []) do
    key = Keyword.get(opts, :channel, channel.key)

    values =
      saver
      |> Checkpoint.list(history_config(config))
      |> Enum.reverse()
      |> Enum.flat_map(&history_values(&1, key))

    update(%{channel | value: channel.initial}, values)
  end

  defp history_values(tuple, key) do
    tuple
    |> Map.get(:pending_write_records, [])
    |> case do
      [] -> tuple_fallback_values(tuple, key)
      records -> record_values(records, key)
    end
  end

  defp record_values(records, key) do
    records
    |> Enum.filter(&(to_string(&1.channel) == to_string(key)))
    |> Enum.map(& &1.value)
  end

  defp tuple_fallback_values(tuple, key) do
    key = to_string(key)

    tuple
    |> Map.get(:pending_writes, [])
    |> Enum.flat_map(fn
      {_task_id, channel, value} ->
        if to_string(channel) == key, do: [value], else: []

      {_task_id, channel, value, _path} ->
        if to_string(channel) == key, do: [value], else: []

      _other ->
        []
    end)
  end

  defp history_config(config) do
    configurable =
      config
      |> Checkpoint.configurable()
      |> Map.delete("checkpoint_id")

    %{"configurable" => configurable}
  end

  defp current_value(%__MODULE__{value: value, initial: initial}) do
    if value == Channel.missing(), do: initial, else: value
  end

  defp split_overwrite(_channel, updates) do
    overwrites =
      updates
      |> Enum.with_index()
      |> Enum.flat_map(fn {value, index} ->
        case Overwrite.get(value) do
          {:ok, overwrite_value} -> [{overwrite_value, index}]
          :error -> []
        end
      end)

    case overwrites do
      [] ->
        {:ok, :current, updates}

      [{value, index}] ->
        remaining =
          updates
          |> Enum.with_index()
          |> Enum.reject(fn {_value, update_index} -> update_index == index end)
          |> Enum.map(fn {value, _index} -> value end)

        {:ok, value, remaining}

      _many ->
        {:error, "delta channel can receive only one overwrite per step"}
    end
  end

  defp replay_split(_channel, []), do: {:ok, :current, []}

  defp replay_split(_channel, updates) do
    updates
    |> Enum.with_index()
    |> Enum.reduce({:current, 0}, fn {value, index}, {base, start} ->
      case Overwrite.get(value) do
        {:ok, overwrite_value} -> {overwrite_value, index + 1}
        :error -> {base, start}
      end
    end)
    |> then(fn {base, start} -> {:ok, base, Enum.drop(updates, start)} end)
  end
end
