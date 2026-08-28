defmodule BeamWeaver.Provider.ReasoningControlTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Models.Profile
  alias BeamWeaver.Provider.ReasoningControl

  test "resolves bounded fixed Anthropic thinking" do
    profile = %Profile{
      reasoning_output: true,
      extra: %{effort_levels: [:low, :medium, :high]}
    }

    assert {:ok, %{thinking: %{type: "enabled", budget_tokens: 2_000}}} =
             ReasoningControl.resolve(profile, :anthropic, :medium, 10_000)
  end

  test "resolves adaptive thinking from persisted string-key profile metadata" do
    profile = %Profile{
      reasoning_output: true,
      extra: %{"thinking_mode" => "adaptive_only", "effort_levels" => ["low", "high"]}
    }

    assert {:ok, %{thinking: %{type: "adaptive"}, effort: "high"}} =
             ReasoningControl.resolve(profile, :anthropic, "high", 10_000)
  end

  test "rejects malformed and unknown efforts instead of silently disabling reasoning" do
    profile = %Profile{reasoning_output: true}

    assert {:error, %{type: :incompatible_reasoning_effort}} =
             ReasoningControl.resolve(profile, :anthropic, %{level: "high"}, 10_000)

    assert {:error, %{type: :incompatible_reasoning_effort}} =
             ReasoningControl.resolve(profile, :anthropic, "extreme", 10_000)
  end

  test "honors the canonical reasoning_efforts profile key" do
    profile = %Profile{reasoning_output: true, extra: %{reasoning_efforts: [:low, :high]}}

    assert {:error, %{type: :incompatible_reasoning_effort}} =
             ReasoningControl.resolve(profile, :anthropic, :medium, 10_000)

    assert {:error, %{type: :incompatible_reasoning_effort}} =
             ReasoningControl.resolve(profile, :anthropic, :high, -1)
  end
end
