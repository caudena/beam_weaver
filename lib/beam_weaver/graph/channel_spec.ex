defmodule BeamWeaver.Graph.ChannelSpec do
  @moduledoc """
  Explicit state-schema channel declaration.

  This is BeamWeaver's Elixir-native equivalent of LangGraph's channel
  annotations. It keeps schema metadata as normal data instead of relying on
  Python-style type annotations.
  """

  defstruct [
    :channel,
    opts: [],
    subscribers: [],
    visibility: :public,
    managed?: false
  ]

  @type visibility :: :public | :private

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
        |> Keyword.drop([:subscribers, :subscriber, :triggers, :visibility, :private]),
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
  def private(channel, opts \\ []), do: new(channel, Keyword.put(opts, :visibility, :private))

  @spec managed(term(), keyword()) :: t()
  def managed(managed, opts \\ []) do
    new(managed, opts |> Keyword.put(:managed?, true) |> Keyword.put(:visibility, :private))
  end

  defp visibility(opts) do
    cond do
      Keyword.get(opts, :private, false) -> :private
      Keyword.get(opts, :visibility) in [:private, "private"] -> :private
      true -> :public
    end
  end
end
