defmodule BeamWeaver.Graph.Channels.UntrackedValue do
  @moduledoc """
  Channel that stores a value during execution but never checkpoints it.
  """

  use BeamWeaver.Graph.Channel

  alias BeamWeaver.Graph.Channel

  defstruct [:key, value: Channel.missing(), guard: true]

  def new(opts \\ []),
    do: %__MODULE__{key: Keyword.get(opts, :key), guard: Keyword.get(opts, :guard, true)}

  @impl true
  def update(channel, []), do: {:ok, channel, false}

  def update(%__MODULE__{guard: true, key: key}, [_one, _two | _rest]) do
    {:error,
     Channel.invalid_update("untracked channel can receive only one value per step", %{
       channel: key
     })}
  end

  def update(channel, values), do: {:ok, %{channel | value: List.last(values)}, true}

  @impl true
  def get(%__MODULE__{value: value, key: key}) do
    if value == Channel.missing(), do: {:error, Channel.empty_error(key)}, else: {:ok, value}
  end

  @impl true
  def checkpoint(_channel), do: Channel.missing()

  @impl true
  def from_checkpoint(channel, _checkpoint), do: %{channel | value: Channel.missing()}

  @impl true
  def available?(%__MODULE__{value: value}), do: value != Channel.missing()
end
