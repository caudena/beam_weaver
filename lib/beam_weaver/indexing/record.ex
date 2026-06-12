defmodule BeamWeaver.Indexing.Record do
  @moduledoc """
  Durable bookkeeping record for indexed documents.
  """

  @enforce_keys [:id, :source_id, :hash]
  defstruct [:id, :source_id, :hash, namespace: :default, metadata: %{}, updated_at: nil]

  @type t :: %__MODULE__{
          id: String.t(),
          source_id: String.t(),
          hash: String.t(),
          namespace: term(),
          metadata: map(),
          updated_at: term()
        }
end
