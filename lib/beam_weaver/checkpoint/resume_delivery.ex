defmodule BeamWeaver.Checkpoint.ResumeDelivery do
  @moduledoc """
  Immutable input for strict, receipt-backed parent-lane result delivery.

  A resume delivery is first staged as a pending checkpoint write and is then
  consumed by `BeamWeaver.Checkpoint.continue_staged/2`.  The two phases keep
  result delivery replayable without treating an application database flag as
  checkpoint evidence.
  """

  alias BeamWeaver.Compaction.Canonical
  alias BeamWeaver.Core.Error

  @enforce_keys [
    :delivery_id,
    :source_checkpoint_id,
    :source_ordinal,
    :payload,
    :payload_hash,
    :terminal_evidence
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          delivery_id: String.t(),
          source_checkpoint_id: String.t(),
          source_ordinal: non_neg_integer(),
          payload: map(),
          payload_hash: String.t(),
          terminal_evidence: map()
        }

  @max_payload_bytes 128 * 1024

  @spec new(map()) :: {:ok, t()} | {:error, Error.t()}
  def new(attrs) when is_map(attrs) do
    delivery = %__MODULE__{
      delivery_id: value(attrs, :delivery_id),
      source_checkpoint_id: value(attrs, :source_checkpoint_id),
      source_ordinal: value(attrs, :source_ordinal),
      payload: value(attrs, :payload),
      payload_hash: value(attrs, :payload_hash),
      terminal_evidence: value(attrs, :terminal_evidence)
    }

    with :ok <- validate_text(delivery.delivery_id, :delivery_id),
         :ok <- validate_text(delivery.source_checkpoint_id, :source_checkpoint_id),
         true <- is_integer(delivery.source_ordinal) and delivery.source_ordinal >= 0,
         true <- is_map(delivery.payload) and is_map(delivery.terminal_evidence),
         true <- Canonical.json_value?(delivery.payload),
         true <- Canonical.json_value?(delivery.terminal_evidence),
         true <- Canonical.hash(delivery.payload) == delivery.payload_hash,
         {:ok, size} <- Canonical.encoded_size(to_map(delivery)),
         true <- size <= @max_payload_bytes do
      {:ok, delivery}
    else
      false -> invalid()
      {:error, _reason} -> invalid()
    end
  rescue
    _error -> invalid()
  end

  def new(_attrs), do: invalid()

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = delivery) do
    %{
      "schema_version" => 1,
      "delivery_id" => delivery.delivery_id,
      "source_checkpoint_id" => delivery.source_checkpoint_id,
      "source_ordinal" => delivery.source_ordinal,
      "payload" => delivery.payload,
      "payload_hash" => delivery.payload_hash,
      "terminal_evidence" => delivery.terminal_evidence
    }
  end

  @spec claim_hash(t()) :: String.t()
  def claim_hash(%__MODULE__{} = delivery), do: Canonical.hash(to_map(delivery))

  @spec task_id(t()) :: String.t()
  def task_id(%__MODULE__{delivery_id: id}), do: "resume_delivery:" <> id

  @spec result_checkpoint_id(t()) :: String.t()
  def result_checkpoint_id(%__MODULE__{} = delivery) do
    "resume-" <> String.slice(claim_hash(delivery), 0, 48)
  end

  defp validate_text(value, _field)
       when is_binary(value) and value != "" and byte_size(value) <= 512,
       do: :ok

  defp validate_text(_value, _field), do: invalid()

  defp invalid do
    {:error, Error.new(:invalid_resume_delivery, "resume delivery is malformed or exceeds its bounds")}
  end

  defp value(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end

defmodule BeamWeaver.Checkpoint.ResumeDelivery.StageReceipt do
  @moduledoc """
  Verified receipt proving that one exact resume delivery is present among an
  exact source checkpoint's pending writes.

  Applications normally obtain this value from
  `BeamWeaver.Checkpoint.stage_resume/3` and pass it unchanged to
  `BeamWeaver.Checkpoint.continue_staged/2`.
  """
  alias BeamWeaver.Checkpoint.ResumeDelivery

  @enforce_keys [:delivery, :source_config, :claim_hash, :receipt_hash]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          delivery: ResumeDelivery.t(),
          source_config: map(),
          claim_hash: String.t(),
          receipt_hash: String.t()
        }
end

defmodule BeamWeaver.Checkpoint.ResumeDelivery.CommitReceipt do
  @moduledoc """
  Verified identity and hash evidence for a committed resume-delivery
  checkpoint.

  Applications normally obtain this value from
  `BeamWeaver.Checkpoint.continue_staged/2` and verify it with
  `BeamWeaver.Checkpoint.verify_resume_receipt/2` during recovery.
  """
  @enforce_keys [
    :delivery_id,
    :source_checkpoint_id,
    :resulting_config,
    :resulting_checkpoint_id,
    :claim_hash,
    :checkpoint_hash,
    :receipt_hash
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          delivery_id: String.t(),
          source_checkpoint_id: String.t(),
          resulting_config: map(),
          resulting_checkpoint_id: String.t(),
          claim_hash: String.t(),
          checkpoint_hash: String.t(),
          receipt_hash: String.t()
        }
end
