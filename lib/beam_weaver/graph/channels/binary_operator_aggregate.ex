defmodule BeamWeaver.Graph.Channels.BinaryOperatorAggregate do
  @moduledoc """
  Channel that folds updates through a binary reducer.
  """

  use BeamWeaver.Graph.Channel

  alias BeamWeaver.Graph.Channel

  defstruct [:key, :operator, value: Channel.missing(), initial: Channel.missing()]

  def new(operator, opts \\ []) when is_function(operator, 2) do
    initial = Keyword.get(opts, :initial, Channel.missing())

    %__MODULE__{
      key: Keyword.get(opts, :key),
      operator: operator,
      value: initial,
      initial: initial
    }
  end

  @impl true
  def update(channel, []), do: {:ok, channel, false}

  def update(%__MODULE__{} = channel, updates) do
    case apply_updates(channel.value, updates, channel.operator, false) do
      {:ok, value} -> {:ok, %{channel | value: value}, true}
      {:error, reason} -> {:error, Channel.invalid_update(reason, %{channel: channel.key})}
    end
  end

  @impl true
  def get(%__MODULE__{value: value, key: key}) do
    if value == Channel.missing(), do: {:error, Channel.empty_error(key)}, else: {:ok, value}
  end

  @impl true
  def checkpoint(%__MODULE__{value: value}), do: value

  @impl true
  def from_checkpoint(channel, checkpoint) do
    if checkpoint == Channel.missing(),
      do: %{channel | value: channel.initial},
      else: %{channel | value: checkpoint}
  end

  @impl true
  def available?(%__MODULE__{value: value}), do: value != Channel.missing()

  defp apply_updates(value, [], _operator, _seen_overwrite), do: {:ok, value}

  defp apply_updates(value, [update | rest], operator, seen_overwrite) do
    case BeamWeaver.Graph.Overwrite.get(update) do
      {:ok, overwrite_value} ->
        if seen_overwrite do
          {:error, "aggregate channel can receive only one overwrite per step"}
        else
          apply_updates(overwrite_value, rest, operator, true)
        end

      :error ->
        next =
          cond do
            seen_overwrite -> value
            value == Channel.missing() -> update
            true -> operator.(value, update)
          end

        apply_updates(next, rest, operator, seen_overwrite)
    end
  end
end
