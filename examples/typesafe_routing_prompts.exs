defmodule BeamWeaver.Examples.TypeSafeRouting.Prompts do
  @moduledoc false

  # Shared by the live example and its separate evaluation set. Keep the rubric
  # fixed while measuring held-out cases; do not tune it against those results.
  def choices(fast, powerful) do
    %{
      "fast" => %{
        model: fast,
        criteria: %{
          covers: "Direct lookup, extraction, localized changes, or invoking a specified tool with known inputs.",
          excludes: "Architecture design, novel diagnosis, or consequential tradeoffs.",
          examples: ["Call a calculator with supplied operands", "Correct a spelling error"]
        }
      },
      "powerful" => %{
        model: powerful,
        criteria: %{
          covers:
            "Architecture design, novel root-cause analysis, and decisions requiring substantial reasoning about correctness.",
          excludes: "Mechanical execution of a supplied operation.",
          examples: ["Design distributed consistency and recovery", "Diagnose an unexplained intermittent failure"]
        }
      }
    }
  end
end
