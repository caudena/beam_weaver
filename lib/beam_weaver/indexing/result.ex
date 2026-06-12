defmodule BeamWeaver.Indexing.Result do
  @moduledoc """
  Result counters for an indexing run.
  """

  defstruct added: 0,
            updated: 0,
            skipped: 0,
            deleted: 0,
            failed: 0,
            errors: [],
            indexed_ids: [],
            deleted_ids: []

  @type t :: %__MODULE__{}
end
