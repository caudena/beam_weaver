defmodule BeamWeaver.Graph.Channels.AnyValue do
  @moduledoc """
  Channel that keeps the latest value and accepts several writes in one step.

  Use it for a value that parallel nodes may all write, as long as they agree
  on it: the last write of the step is kept. The value stays until it is
  written again.
  """

  use BeamWeaver.Graph.Channel

  alias BeamWeaver.Graph.Channel

  defstruct [:key, value: Channel.missing()]

  def new(opts \\ []), do: %__MODULE__{key: Keyword.get(opts, :key)}

  @impl true
  def update(channel, []), do: {:ok, channel, false}

  def update(channel, values), do: {:ok, %{channel | value: List.last(values)}, true}
end
