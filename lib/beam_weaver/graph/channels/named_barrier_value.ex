defmodule BeamWeaver.Graph.Channels.NamedBarrierValue do
  @moduledoc """
  Channel that becomes available after all configured names are seen.
  """

  use BeamWeaver.Graph.Channel

  alias BeamWeaver.Graph.Channel

  defstruct [:key, names: MapSet.new(), seen: MapSet.new()]

  def new(names, opts \\ []) do
    %__MODULE__{key: Keyword.get(opts, :key), names: MapSet.new(names)}
  end

  @impl true
  def update(channel, values) do
    Enum.reduce_while(values, {:ok, channel, false}, fn value, {:ok, acc, updated?} ->
      cond do
        not MapSet.member?(acc.names, value) ->
          {:halt,
           {:error,
            Channel.invalid_update("barrier value is not in the allowed names", %{
              channel: acc.key,
              value: value
            })}}

        MapSet.member?(acc.seen, value) ->
          {:cont, {:ok, acc, updated?}}

        true ->
          {:cont, {:ok, %{acc | seen: MapSet.put(acc.seen, value)}, true}}
      end
    end)
  end

  @impl true
  def get(channel) do
    if available?(channel), do: {:ok, nil}, else: {:error, Channel.empty_error(channel.key)}
  end

  @impl true
  def checkpoint(%__MODULE__{seen: seen}), do: MapSet.to_list(seen)

  @impl true
  def from_checkpoint(channel, checkpoint) do
    seen = if checkpoint == Channel.missing(), do: [], else: checkpoint
    %{channel | seen: MapSet.new(seen)}
  end

  @impl true
  def available?(%__MODULE__{names: names, seen: seen}), do: MapSet.equal?(names, seen)

  @impl true
  def consume(channel) do
    if available?(channel),
      do: {:ok, %{channel | seen: MapSet.new()}, true},
      else: {:ok, channel, false}
  end
end

defmodule BeamWeaver.Graph.Channels.NamedBarrierValueAfterFinish do
  @moduledoc """
  Barrier channel that becomes available only after all names are seen and `finish/1` runs.
  """

  use BeamWeaver.Graph.Channel

  alias BeamWeaver.Graph.Channel

  defstruct [:key, names: MapSet.new(), seen: MapSet.new(), finished?: false]

  def new(names, opts \\ []) do
    %__MODULE__{key: Keyword.get(opts, :key), names: MapSet.new(names)}
  end

  @impl true
  def update(channel, values) do
    Enum.reduce_while(values, {:ok, channel, false}, fn value, {:ok, acc, updated?} ->
      cond do
        not MapSet.member?(acc.names, value) ->
          {:halt,
           {:error,
            Channel.invalid_update("barrier value is not in the allowed names", %{
              channel: acc.key,
              value: value
            })}}

        MapSet.member?(acc.seen, value) ->
          {:cont, {:ok, acc, updated?}}

        true ->
          {:cont, {:ok, %{acc | seen: MapSet.put(acc.seen, value), finished?: false}, true}}
      end
    end)
  end

  @impl true
  def get(channel) do
    if available?(channel), do: {:ok, nil}, else: {:error, Channel.empty_error(channel.key)}
  end

  @impl true
  def checkpoint(%__MODULE__{seen: seen, finished?: finished?}),
    do: {MapSet.to_list(seen), finished?}

  @impl true
  def from_checkpoint(channel, checkpoint) do
    if checkpoint == Channel.missing() do
      %{channel | seen: MapSet.new(), finished?: false}
    else
      {seen, finished?} = checkpoint
      %{channel | seen: MapSet.new(seen), finished?: finished?}
    end
  end

  @impl true
  def available?(%__MODULE__{names: names, seen: seen, finished?: finished?}),
    do: finished? and MapSet.equal?(names, seen)

  @impl true
  def consume(channel) do
    if available?(channel) do
      {:ok, %{channel | seen: MapSet.new(), finished?: false}, true}
    else
      {:ok, channel, false}
    end
  end

  @impl true
  def finish(%__MODULE__{names: names, seen: seen, finished?: false} = channel) do
    if MapSet.equal?(names, seen),
      do: {:ok, %{channel | finished?: true}, true},
      else: {:ok, channel, false}
  end

  def finish(channel), do: {:ok, channel, false}
end
