defmodule BeamWeaver.DeepAgents.Evals.ReportingTest do
  use ExUnit.Case, async: false

  alias BeamWeaver.TestSupport.DeepAgents.Evals
  alias BeamWeaver.TestSupport.DeepAgents.Evals.{Failure, Radar, Stats}

  test "radar and markdown trial summaries use category scores" do
    trials = Evals.trials(trials: 1, category: "file_operations")
    aggregate = Evals.aggregate(trials)

    assert %{"axes" => [%{"name" => "file_operations", "label" => "File Ops", "value" => 1.0}]} =
             Evals.radar(aggregate)

    markdown = Evals.trial_summary_markdown(trials)

    assert markdown =~ "DeepAgents eval trials"
    assert markdown =~ "Per-trial correctness by category"
    assert markdown =~ "File Ops"
  end

  test "per-trial category matrix preserves order, precision, missing scores, and escapes labels" do
    trials = [
      %{"trial_index" => 1, "category_scores" => %{"memory" => 0.875, "weird" => 0.0}},
      %{"trial_index" => 2, "category_scores" => %{"memory" => 1.0}}
    ]

    lines =
      Evals.render_per_trial_category_matrix(
        trials,
        ["weird", "memory"],
        %{"weird" => "Has | pipe\nand\\slash", "memory" => "Memory"},
        places: 2
      )

    assert lines == [
             "",
             "### Per-trial correctness by category",
             "",
             "| # | Has \\| pipe and\\\\slash | Memory |",
             "|---:|---:|---:|",
             "| 1 | 0.00 | 0.88 |",
             "| 2 | - | 1.00 |"
           ]
  end

  test "radar helpers, failure classification, and stats are available" do
    aggregate = Evals.trials(trials: 1, category: "file_operations") |> Evals.aggregate()
    radar = Radar.generate_radar(aggregate)

    assert radar["axes"] == [
             %{"label" => "File Ops", "name" => "file_operations", "value" => 1.0}
           ]

    individual =
      Radar.generate_individual_radars(%{
        "models" => %{"fake" => aggregate}
      })

    assert Map.has_key?(individual, "fake")

    assert Failure.classify_failure("exit code 124 timeout") == "timeout"
    assert Failure.extract_exit_codes("status 2, exit code 9") == [2, 9]

    assert {low, high} = Stats.wilson_ci(9, 10)
    assert low < high
    assert Stats.format_ci({0.1, 0.9}, 1) == "0.1-0.9"
  end
end
