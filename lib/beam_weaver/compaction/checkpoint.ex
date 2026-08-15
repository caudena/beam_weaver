defmodule BeamWeaver.Compaction.Checkpoint do
  @moduledoc "Immutable derived context checkpoint; it is not executable graph authority."

  @enforce_keys [
    :checkpoint_id,
    :thread_id,
    :run_id,
    :root_turn_id,
    :run_agent_id,
    :checkpoint_namespace,
    :trigger,
    :representation,
    :source_chat_seq_range,
    :summary_coverage_last_chat_seq,
    :context_chat_seq_high_watermark,
    :retained_from_chat_seq,
    :source_lane_event_ordinal_range,
    :summary_coverage_last_lane_event_ordinal,
    :context_lane_event_ordinal_high_watermark,
    :semantic,
    :semantic_hash,
    :rehydration_state,
    :rehydration_state_hash,
    :provider_connection_id,
    :destination_identity_hash,
    :token_counter,
    :tokens_before,
    :tokens_after,
    :tokens_reclaimed,
    :retained_event_ids,
    :validation_status,
    :created_at
  ]
  defstruct @enforce_keys ++ [:parent_checkpoint_id, :projection_manifest, :provider_usage]

  @type t :: %__MODULE__{}

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = checkpoint) do
    checkpoint
    |> Map.from_struct()
    |> Map.put(:id, checkpoint.checkpoint_id)
    |> Map.update!(:source_chat_seq_range, &range_map/1)
    |> Map.update!(:source_lane_event_ordinal_range, &range_map/1)
    |> Map.update!(:semantic, fn
      nil -> nil
      semantic -> BeamWeaver.Compaction.Semantic.to_map(semantic)
    end)
    |> Map.update!(:rehydration_state, & &1.data)
    |> Map.update!(:trigger, &Atom.to_string/1)
    |> Map.update!(:representation, &Atom.to_string/1)
    |> Map.update!(:token_counter, &Atom.to_string/1)
    |> Map.update!(:validation_status, &Atom.to_string/1)
  end

  defp range_map({first, last}), do: %{first: first, last: last}
end
