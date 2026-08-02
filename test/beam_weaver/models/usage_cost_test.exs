defmodule BeamWeaver.Models.UsageCostTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Models.Profile
  alias BeamWeaver.Models.UsageCost

  @profile Profile.new(%{
             provider: :test,
             id: "priced-model",
             extra: %{
               input_price_per_mtok: 2.0,
               cached_input_price_per_mtok: 0.5,
               output_price_per_mtok: 4.0
             }
           })

  test "derives uncached input from total input and cached tokens" do
    costs =
      UsageCost.calculate(@profile, %{
        input_tokens: 100,
        output_tokens: 20,
        input_token_details: %{cache_read: 40},
        output_token_details: %{reasoning: 15}
      })

    assert_in_delta costs.input_cost_details.uncached, 0.00012, 1.0e-12
    assert_in_delta costs.input_cost_details.cache_read, 0.00002, 1.0e-12
    assert_in_delta costs.input_cost, 0.00014, 1.0e-12
    assert_in_delta costs.output_cost, 0.00008, 1.0e-12
    assert_in_delta costs.total_cost, 0.00022, 1.0e-12
    assert costs.output_cost_details == %{text: costs.output_cost}
  end

  test "prefers explicit cache hit and miss counts without billing reasoning twice" do
    costs =
      UsageCost.calculate(@profile, %{
        "prompt_tokens" => 100,
        "completion_tokens" => 20,
        "prompt_cache_hit_tokens" => 30,
        "prompt_cache_miss_tokens" => 10,
        "completion_tokens_details" => %{"reasoning_tokens" => 20}
      })

    assert_in_delta costs.input_cost_details.uncached, 0.00002, 1.0e-12
    assert_in_delta costs.input_cost_details.cache_read, 0.000015, 1.0e-12
    assert_in_delta costs.output_cost, 0.00008, 1.0e-12
    assert_in_delta costs.total_cost, 0.000115, 1.0e-12
  end

  test "uses the normal input rate when a profile has no cached-input rate" do
    profile = %{
      "extra" => %{
        "input_price_per_mtok" => 1.0,
        "output_price_per_mtok" => 3.0
      }
    }

    costs =
      UsageCost.calculate(profile, %{
        prompt_tokens: 10,
        completion_tokens: 2,
        prompt_tokens_details: %{cached_tokens: 4}
      })

    assert_in_delta costs.input_cost, 0.00001, 1.0e-12
    assert_in_delta costs.output_cost, 0.000006, 1.0e-12
  end

  test "returns nil when canonical profile pricing is unavailable" do
    assert UsageCost.calculate(Profile.new(%{provider: :test, id: "free"}), %{input_tokens: 10}) == nil
    assert UsageCost.calculate(nil, %{input_tokens: 10}) == nil
  end
end
