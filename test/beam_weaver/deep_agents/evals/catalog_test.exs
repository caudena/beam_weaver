defmodule BeamWeaver.DeepAgents.Evals.CatalogTest do
  use ExUnit.Case, async: false

  alias BeamWeaver.TestSupport.DeepAgents.Evals

  test "catalog and model groups expose ported and skipped eval metadata" do
    assert Enum.any?(Evals.catalog(), fn row ->
             row["category"] == "file_operations" and row["eval_count"] == 13 and
               row["label"] == "File Ops"
           end)

    assert Enum.all?(Evals.catalog(), &(&1["status"] == "ported"))

    assert "fake" in Evals.model_groups()["core"]

    assert Evals.radar_categories() ==
             ~w(file_operations retrieval tool_use memory conversation summarization)
  end
end
