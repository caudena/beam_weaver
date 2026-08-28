defmodule BeamWeaver.Checkpoint.ResumeDeliveryTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Checkpoint
  alias BeamWeaver.Checkpoint.ETS
  alias BeamWeaver.Checkpoint.ResumeDelivery
  alias BeamWeaver.Checkpoint.ResumeDelivery.{CommitReceipt, StageReceipt}
  alias BeamWeaver.Compaction.Canonical

  test "stage receipts bind the validated delivery to its source owner" do
    delivery = delivery()

    source_config = %{
      "configurable" => %{
        "thread_id" => "thread-1",
        "checkpoint_ns" => "root",
        "checkpoint_id" => delivery.source_checkpoint_id
      }
    }

    stage = %StageReceipt{
      delivery: delivery,
      source_config: source_config,
      claim_hash: ResumeDelivery.claim_hash(delivery),
      receipt_hash: Checkpoint.stage_receipt_hash(delivery, source_config)
    }

    assert :ok = Checkpoint.verify_stage_receipt(stage)

    assert {:error, %{type: :invalid_resume_receipt}} =
             Checkpoint.verify_stage_receipt(%{stage | claim_hash: String.duplicate("0", 64)})

    other_thread = put_in(source_config, ["configurable", "thread_id"], "thread-2")

    assert {:error, %{type: :invalid_resume_receipt}} =
             Checkpoint.verify_stage_receipt(%{stage | source_config: other_thread})
  end

  test "commit receipt hashes include the resulting checkpoint owner" do
    receipt = %CommitReceipt{
      delivery_id: "delivery-1",
      source_checkpoint_id: "checkpoint-1",
      resulting_config: %{
        "configurable" => %{
          "thread_id" => "thread-1",
          "checkpoint_ns" => "root",
          "checkpoint_id" => "checkpoint-2"
        }
      },
      resulting_checkpoint_id: "checkpoint-2",
      claim_hash: String.duplicate("a", 64),
      checkpoint_hash: String.duplicate("b", 64),
      receipt_hash: ""
    }

    other_thread = put_in(receipt.resulting_config, ["configurable", "thread_id"], "thread-2")

    refute Checkpoint.commit_receipt_hash(receipt) ==
             Checkpoint.commit_receipt_hash(%{receipt | resulting_config: other_thread})
  end

  test "staging canonicalizes atom-keyed and keyword checkpoint configs" do
    saver = ETS.new()

    configs = [
      [configurable: [thread_id: "keyword-thread"]],
      %{configurable: %{thread_id: "atom-keyed-thread"}}
    ]

    for config <- configs do
      thread_id = Checkpoint.configurable(config)["thread_id"]

      assert {:ok, source_config} =
               Checkpoint.put(
                 saver,
                 config,
                 %{"id" => "#{thread_id}-source"},
                 %{},
                 %{}
               )

      delivery = delivery(source_checkpoint_id: "#{thread_id}-source")

      assert {:ok, stage} = Checkpoint.stage_resume(saver, source_config, delivery)
      assert Checkpoint.configurable(stage.source_config)["thread_id"] == thread_id
      assert Checkpoint.configurable(stage.source_config)["checkpoint_id"] == delivery.source_checkpoint_id
      assert :ok = Checkpoint.verify_stage_receipt(stage)
    end
  end

  defp delivery(opts \\ []) do
    payload = %{"result" => "done"}

    {:ok, delivery} =
      ResumeDelivery.new(%{
        delivery_id: "delivery-1",
        source_checkpoint_id: Keyword.get(opts, :source_checkpoint_id, "checkpoint-1"),
        source_ordinal: 1,
        payload: payload,
        payload_hash: Canonical.hash(payload),
        terminal_evidence: %{"state" => "completed"}
      })

    delivery
  end
end
