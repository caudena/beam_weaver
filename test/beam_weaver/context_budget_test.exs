defmodule BeamWeaver.ContextBudgetTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.ContextBudget
  alias BeamWeaver.Models.Profile

  test "uses explicit separate and shared context semantics" do
    assert {:ok, separate} =
             ContextBudget.new(
               %Profile{max_input_tokens: 10_000, provider_reserved_tokens: 100},
               String.duplicate("x", 2_000)
             )

    assert separate.effective_input_limit == 9_900
    assert separate.estimated_tokens == 2_000

    assert {:ok, shared} =
             ContextBudget.new(
               %Profile{
                 context_limit_kind: :shared_input_output,
                 max_context_tokens: 10_000,
                 max_output_tokens: 2_000,
                 provider_reserved_tokens: 100
               },
               "request",
               requested_max_output_tokens: 1_500
             )

    assert shared.effective_input_limit == 8_400
  end

  test "fails closed when limit semantics are unknown" do
    assert {:error, error} =
             ContextBudget.new(%Profile{context_limit_kind: :unknown}, "request")

    assert error.type == :unknown_context_limit
  end
end
