defmodule BeamWeaver.Graph.Channels.Topic do
  @moduledoc """
  Pub/sub-style channel that stores a list of values.
  """

  use BeamWeaver.Graph.Channel

  alias BeamWeaver.Graph.Channel

  defstruct [:key, values: [], accumulate: false]

  def new(opts \\ []) do
    %__MODULE__{key: Keyword.get(opts, :key), accumulate: Keyword.get(opts, :accumulate, false)}
  end

  @impl true
  def update(channel, updates) do
    values = if channel.accumulate, do: channel.values, else: []
    flattened = Enum.flat_map(updates, &List.wrap/1)
    next = %{channel | values: values ++ flattened}
    {:ok, next, next.values != channel.values}
  end

  @impl true
  def get(%__MODULE__{values: [], key: key}), do: {:error, Channel.empty_error(key)}
  def get(%__MODULE__{values: values}), do: {:ok, values}

  @impl true
  def checkpoint(%__MODULE__{values: values}), do: values

  @impl true
  def from_checkpoint(channel, checkpoint) do
    cond do
      checkpoint == Channel.missing() ->
        %{channel | values: []}

      is_tuple(checkpoint) and tuple_size(checkpoint) >= 2 ->
        %{channel | values: List.wrap(elem(checkpoint, 1))}

      true ->
        %{channel | values: List.wrap(checkpoint)}
    end
  end

  @impl true
  def available?(%__MODULE__{values: values}), do: values != []
end
