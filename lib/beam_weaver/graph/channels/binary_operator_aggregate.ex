defmodule BeamWeaver.Graph.Channels.BinaryOperatorAggregate do
  @moduledoc """
  Channel that folds updates through a binary reducer.

  When the reducer raises, the update fails with an `:invalid_update` error
  that carries the exception's message.
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
  def from_checkpoint(channel, checkpoint) do
    if checkpoint == Channel.missing(),
      do: %{channel | value: channel.initial},
      else: %{channel | value: checkpoint}
  end

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
        cond do
          seen_overwrite -> apply_updates(value, rest, operator, seen_overwrite)
          value == Channel.missing() -> apply_updates(update, rest, operator, seen_overwrite)
          true -> apply_operator(value, update, rest, operator)
        end
    end
  end

  defp apply_operator(value, update, rest, operator) do
    operator.(value, update)
  rescue
    exception -> {:error, Exception.message(exception)}
  else
    next -> apply_updates(next, rest, operator, false)
  end
end
