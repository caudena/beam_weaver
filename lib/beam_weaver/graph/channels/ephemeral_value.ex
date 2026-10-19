defmodule BeamWeaver.Graph.Channels.EphemeralValue do
  @moduledoc """
  Channel that keeps a write for one step.

  The nodes of the next step read the value; after that step it is cleared,
  unless it was written again. Use it for signals meant for the next node
  only. A step may write it once; pass `guard: false` to keep the last of
  several writes instead.
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
end
