defmodule BeamWeaver.Graph.Channels.AnyValue do
  @moduledoc """
  Channel that stores the latest value and allows multiple equal writes.
  """

  use BeamWeaver.Graph.Channel

  alias BeamWeaver.Graph.Channel

  defstruct [:key, value: Channel.missing()]

  def new(opts \\ []), do: %__MODULE__{key: Keyword.get(opts, :key)}

  @impl true
  def update(%__MODULE__{value: value} = channel, []) do
    if value == Channel.missing() do
      {:ok, channel, false}
    else
      {:ok, %{channel | value: Channel.missing()}, true}
    end
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
