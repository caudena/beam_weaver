defmodule BeamWeaver.Indexing.Result do
  @moduledoc """
  Result counters for an indexing run.

  `failed` counts the documents the vector store or the record manager
  rejected, `failed_ids` lists their ids and `errors` holds the reasons. Old
  chunks of a source with a failed document are not cleaned up, so they stay
  searchable until a later run writes the new ones.
  """

  defstruct added: 0,
            updated: 0,
            skipped: 0,
            deleted: 0,
            failed: 0,
            errors: [],
            indexed_ids: [],
            failed_ids: [],
            deleted_ids: []

  @type t :: %__MODULE__{}
end
