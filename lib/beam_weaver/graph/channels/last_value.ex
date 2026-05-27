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

defmodule BeamWeaver.Graph.Channels.LastValueAfterFinish do
  @moduledoc """
  Last-value channel that is readable only after `finish/1`.
  """

  use BeamWeaver.Graph.Channel

  alias BeamWeaver.Graph.Channel

  defstruct [:key, type: :any, value: Channel.missing(), finished?: false]

  def new(opts \\ []),
    do: %__MODULE__{key: Keyword.get(opts, :key), type: Keyword.get(opts, :type, :any)}

  @impl true
  def update(channel, []), do: {:ok, channel, false}

  def update(channel, values),
    do: {:ok, %{channel | value: List.last(values), finished?: false}, true}

  @impl true
  def get(%__MODULE__{value: value, finished?: finished?, key: key}) do
    if value == Channel.missing() or not finished? do
      {:error, Channel.empty_error(key)}
    else
      {:ok, value}
    end
  end

  @impl true
  def checkpoint(%__MODULE__{value: value, finished?: finished?}) do
    if value == Channel.missing(), do: Channel.missing(), else: {value, finished?}
  end

  @impl true
  def from_checkpoint(channel, checkpoint) do
    if checkpoint == Channel.missing() do
      %{channel | value: Channel.missing(), finished?: false}
    else
      {value, finished?} = checkpoint
      %{channel | value: value, finished?: finished?}
    end
  end

  @impl true
  def available?(%__MODULE__{value: value, finished?: finished?}),
    do: value != Channel.missing() and finished?

  @impl true
  def consume(%__MODULE__{finished?: true} = channel),
    do: {:ok, %{channel | value: Channel.missing(), finished?: false}, true}

  def consume(channel), do: {:ok, channel, false}

  @impl true
  def finish(%__MODULE__{value: value, finished?: false} = channel) do
    if value == Channel.missing(),
      do: {:ok, channel, false},
      else: {:ok, %{channel | finished?: true}, true}
  end

  def finish(channel), do: {:ok, channel, false}
end
