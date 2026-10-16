defmodule BeamWeaver.Graph.ChannelSpec do
  @moduledoc false

  defstruct [
    :channel,
    opts: [],
    subscribers: [],
    visibility: :public,
    managed?: false
  ]

  # `:private_checkpointed` keys stay out of the output like `:private` ones,
  # but are saved in checkpoints, so the next run on a thread starts from them.
  @type visibility :: :public | :private | :private_checkpointed

  @type t :: %__MODULE__{
          channel: term(),
          opts: keyword(),
          subscribers: [atom() | String.t()],
          visibility: visibility(),
          managed?: boolean()
        }

  @spec new(term(), keyword()) :: t()
  def new(channel, opts \\ []) do
    %__MODULE__{
      channel: channel,
      opts:
        opts
        |> Keyword.drop([:subscribers, :subscriber, :triggers, :visibility, :private, :checkpoint]),
      subscribers:
        opts
        |> Keyword.get(
          :subscribers,
          Keyword.get(opts, :subscriber, Keyword.get(opts, :triggers, []))
        )
        |> List.wrap(),
      visibility: visibility(opts),
      managed?: Keyword.get(opts, :managed?, false)
    }
  end

  @spec private(term(), keyword()) :: t()
  def private(channel, opts \\ []) do
    visibility = if Keyword.get(opts, :checkpoint, false), do: :private_checkpointed, else: :private
    new(channel, Keyword.put(opts, :visibility, visibility))
  end

  @spec managed(term(), keyword()) :: t()
  def managed(managed, opts \\ []) do
    new(managed, opts |> Keyword.put(:managed?, true) |> Keyword.put(:visibility, :private))
  end

  defp visibility(opts) do
    cond do
      Keyword.get(opts, :visibility) == :private_checkpointed -> :private_checkpointed
      Keyword.get(opts, :private, false) -> :private
      Keyword.get(opts, :visibility) in [:private, "private"] -> :private
      true -> :public
    end
  end
end
