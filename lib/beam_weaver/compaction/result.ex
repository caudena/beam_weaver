defmodule BeamWeaver.Compaction.Result do
  @moduledoc """
  Pure compaction result awaiting application-owned persistence and activation.

  `status` is `:skipped`, `:pruned`, or `:compacted`. A skipped result has no
  checkpoint. Pruned and compacted results contain an immutable checkpoint,
  the retained source events, referenced artifact IDs, and any provider usage
  returned by the application callback.

  Receiving this struct does not make the checkpoint durable or active.
  """

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
