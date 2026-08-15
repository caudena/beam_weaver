defmodule BeamWeaver.Compaction.Result do
  @moduledoc "Pure compaction result awaiting application-owned persistence and activation."

  @enforce_keys [
    :status,
    :tokens_before,
    :tokens_after,
    :tokens_reclaimed,
    :source_event_count,
    :retained_event_count,
    :retained_events,
    :provider_usage
  ]
  defstruct @enforce_keys ++ [:compaction_checkpoint, artifact_ids: []]

  @type t :: %__MODULE__{}
end
