defmodule BeamWeaver.Memory.Item do
  @moduledoc """
  Typed long-term memory item.
  """

  defstruct [
    :namespace,
    :key,
    :value,
    metadata: %{},
    created_at: nil,
    updated_at: nil,
    expires_at: nil
  ]

  @type t :: %__MODULE__{
          namespace: [String.t()],
          key: String.t(),
          value: term(),
          metadata: map(),
          created_at: DateTime.t(),
          updated_at: DateTime.t(),
          expires_at: DateTime.t() | nil
        }
end

defmodule BeamWeaver.Memory.SearchItem do
  @moduledoc """
  Typed search result wrapper for memory stores.
  """

  defstruct [
    :namespace,
    :key,
    :value,
    :score,
    metadata: %{},
    created_at: nil,
    updated_at: nil,
    expires_at: nil
  ]

  def from_item(item, score \\ nil)

  def from_item(%BeamWeaver.Memory.Item{} = item, score) do
    item
    |> Map.from_struct()
    |> Map.put(:score, score)
    |> then(&struct(__MODULE__, &1))
  end

  def from_item(%{} = item, score) do
    item
    |> Map.put(:score, score)
    |> then(&struct(__MODULE__, &1))
  end
end
