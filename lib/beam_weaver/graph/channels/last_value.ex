defmodule BeamWeaver.Graph.Channels.LastValue do
  @moduledoc """
  Channel that stores the only value received in a step.
  """

  use BeamWeaver.Graph.Channel

  alias BeamWeaver.Graph.Channel

  defstruct [:key, type: :any, value: Channel.missing()]

  def new(opts \\ []),
    do: %__MODULE__{key: Keyword.get(opts, :key), type: Keyword.get(opts, :type, :any)}

  @impl true
  def update(channel, []), do: {:ok, channel, false}

  def update(%__MODULE__{key: key}, [_value, _other | _rest]) do
    {:error,
     Channel.invalid_update("last-value channel can receive only one value per step", %{
       channel: key
     })}
  end

  def update(channel, [value]), do: {:ok, %{channel | value: value}, true}
end
