defmodule BeamWeaver.DeepAgents.Evals.RunnerTest do
  use ExUnit.Case, async: false

  alias BeamWeaver.TestSupport.DeepAgents.Evals

  test "trials aggregate into pass-rate report" do
    report =
      Evals.trials(trials: 2, category: "unit_test")
      |> Evals.aggregate()

    assert report["total"] == 2
    assert report["passed"] == 2
    assert report["skipped"] == 0
    assert report["pass_rate"] == 1.0
    assert report["category_scores"] == %{"unit_test" => 1.0}
    assert report["efficiency"]["step_ratio"] == 1.0
  end

  test "unsupported and gated model runs skip with explicit reasons" do
    unsupported =
      Evals.run(category: "unit_test", model_group: "unsupported_cataloged")
      |> Map.fetch!("results")

    assert Enum.all?(unsupported, &(&1["status"] == "skipped"))
    assert hd(unsupported)["skip_reason"] =~ "not supported by BeamWeaver"

    live =
      Evals.run(category: "file_operations", model: "openai:gpt-4.1")
      |> Map.fetch!("results")
      |> hd()

    assert live["status"] == "skipped"
    assert live["skip_reason"] =~ "live provider evals disabled"
  end

  test "external sandbox evals stay config-gated after porting" do
    BeamWeaver.TestSupport.ConfigHelper.merge_config(:evals, external_sandbox?: false)

    result =
      Evals.run(category: "conversation", include_external_sandbox: true)
      |> Map.fetch!("results")
      |> hd()

    assert result["status"] == "skipped"
    assert result["skip_reason"] =~ "missing BEAM_WEAVER_DEEPAGENTS_SANDBOX"
  end
end
