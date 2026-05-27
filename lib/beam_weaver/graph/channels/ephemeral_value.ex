defmodule BeamWeaver.Graph.Channels.EphemeralValue do
  @moduledoc """
  Channel that stores a value for the next step and clears when no update arrives.
  """

  use BeamWeaver.Graph.Channel

  alias BeamWeaver.Graph.Channel

  defstruct [:key, value: Channel.missing(), guard: true]

  def new(opts \\ []),
    do: %__MODULE__{key: Keyword.get(opts, :key), guard: Keyword.get(opts, :guard, true)}

  @impl true
  def update(%__MODULE__{value: value} = channel, []) do
    if value == Channel.missing() do
      {:ok, channel, false}
    else
      {:ok, %{channel | value: Channel.missing()}, true}
    end
  end

  def update(%__MODULE__{guard: true, key: key}, [_one, _two | _rest]) do
    {:error,
     Channel.invalid_update("ephemeral channel can receive only one value per step", %{
       channel: key
     })}
  end

  def update(channel, values), do: {:ok, %{channel | value: List.last(values)}, true}

  @impl true
  def get(%__MODULE__{value: value, key: key}) do
    if value == Channel.missing(), do: {:error, Channel.empty_error(key)}, else: {:ok, value}
  end

  @impl true
  def checkpoint(%__MODULE__{value: value}), do: value

  @impl true
  def from_checkpoint(channel, checkpoint) do
    if checkpoint == Channel.missing(),
      do: %{channel | value: Channel.missing()},
      else: %{channel | value: checkpoint}
  end

  @impl true
  def available?(%__MODULE__{value: value}), do: value != Channel.missing()
end
