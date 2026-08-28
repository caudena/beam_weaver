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

  test "prices cache writes by TTL without billing them as uncached input" do
    profile = %{
      input_price_per_mtok: 2.0,
      cached_input_price_per_mtok: 0.5,
      cache_write_5m_price_per_mtok: 2.5,
      cache_write_1h_price_per_mtok: 4.0,
      cache_write_30m_price_per_mtok: 3.0,
      output_price_per_mtok: 4.0
    }

    costs =
      UsageCost.calculate(profile, %{
        input_tokens: 100,
        output_tokens: 10,
        input_token_details: %{
          cache_read: 20,
          cache_write_5m_tokens: 10,
          cache_write_1h_tokens: 5,
          cache_write_30m_tokens: 5
        }
      })

    assert_in_delta costs.input_cost_details.uncached, 0.00012, 1.0e-12
    assert_in_delta costs.input_cost_details.cache_read, 0.00001, 1.0e-12
    assert_in_delta costs.input_cost_details.cache_write_5m_tokens, 0.000025, 1.0e-12
    assert_in_delta costs.input_cost_details.cache_write_1h_tokens, 0.00002, 1.0e-12
    assert_in_delta costs.input_cost_details.cache_write_30m_tokens, 0.000015, 1.0e-12
    assert_in_delta costs.input_cost, 0.00019, 1.0e-12
    assert_in_delta costs.output_cost, 0.00004, 1.0e-12
    assert_in_delta costs.total_cost, 0.00023, 1.0e-12
  end

  test "maps a generic cache-write count to the profile's default priced TTL" do
    openai = %{
      input_price_per_mtok: 2.0,
      cache_write_30m_price_per_mtok: 2.5,
      output_price_per_mtok: 4.0
    }

    openai_costs =
      UsageCost.calculate(openai, %{
        input_tokens: 100,
        output_tokens: 0,
        input_token_details: %{cache_write: 20}
      })

    assert_in_delta openai_costs.input_cost_details.uncached, 0.00016, 1.0e-12
    assert_in_delta openai_costs.input_cost_details.cache_write_30m_tokens, 0.00005, 1.0e-12

    anthropic = %{
      input_price_per_mtok: 2.0,
      cache_write_5m_price_per_mtok: 2.5,
      cache_write_1h_price_per_mtok: 4.0,
      output_price_per_mtok: 4.0
    }

    anthropic_costs =
      UsageCost.calculate(anthropic, %{
        input_tokens: 100,
        output_tokens: 0,
        input_token_details: %{cache_creation: 20}
      })

    assert_in_delta anthropic_costs.input_cost_details.uncached, 0.00016, 1.0e-12
    assert_in_delta anthropic_costs.input_cost_details.cache_write_5m_tokens, 0.00005, 1.0e-12
  end

  test "returns nil when canonical profile pricing is unavailable" do
    assert UsageCost.calculate(Profile.new(%{provider: :test, id: "free"}), %{input_tokens: 10}) == nil
    assert UsageCost.calculate(nil, %{input_tokens: 10}) == nil
  end

  test "selects UTC peak rates with inclusive starts and exclusive ends" do
    profile = %{
      "input_price_per_mtok" => 1.0,
      "cached_input_price_per_mtok" => 0.25,
      "output_price_per_mtok" => 2.0,
      "time_based_pricing" => %{
        "default_mode" => "off_peak",
        "peak_windows" => [
          %{"start_minute" => 60, "end_minute" => 240},
          %{"start_minute" => 360, "end_minute" => 600}
        ],
        "off_peak" => %{
          "input_price_per_mtok" => 1.0,
          "cached_input_price_per_mtok" => 0.25,
          "output_price_per_mtok" => 2.0
        },
        "peak" => %{
          "input_price_per_mtok" => 2.0,
          "cached_input_price_per_mtok" => 0.5,
          "output_price_per_mtok" => 4.0
        }
      }
    }

    usage = %{input_tokens: 10, cached_tokens: 4, output_tokens: 5}

    for at <- [
          ~U[2026-08-13 01:00:00Z],
          ~U[2026-08-13 03:59:59Z],
          ~U[2026-08-13 06:00:00Z],
          ~U[2026-08-13 09:59:59Z]
        ] do
      costs = UsageCost.calculate(profile, usage, at: at)
      assert_in_delta costs.total_cost, 0.000034, 1.0e-12
    end

    for at <- [
          ~U[2026-08-13 00:59:59Z],
          ~U[2026-08-13 04:00:00Z],
          ~U[2026-08-13 05:59:59Z],
          ~U[2026-08-13 10:00:00Z]
        ] do
      costs = UsageCost.calculate(profile, usage, at: at)
      assert_in_delta costs.total_cost, 0.000017, 1.0e-12
    end
  end

  test "uses canonical off-peak rates when no timestamp is available" do
    profile = %{
      input_price_per_mtok: 1.0,
      output_price_per_mtok: 2.0,
      time_based_pricing: %{
        default_mode: :off_peak,
        peak_windows: [%{start_minute: 0, end_minute: 1_440}],
        peak: %{input_price_per_mtok: 10.0, output_price_per_mtok: 20.0}
      }
    }

    costs = UsageCost.calculate(profile, %{input_tokens: 10, output_tokens: 5})
    assert_in_delta costs.total_cost, 0.00002, 1.0e-12
  end

  test "calculates exact USD micros with one final rounding step" do
    pricing = %{
      "schema_version" => 1,
      "currency" => "USD",
      "rounding" => "half_up",
      "dimensions" => [
        %{
          "name" => "input_tokens",
          "unit_size" => 1_000_000,
          "unit_price_usd_micros" => 2_000_000
        },
        %{
          "name" => "cached_input_tokens",
          "unit_size" => 1_000_000,
          "unit_price_usd_micros" => 500_000
        },
        %{
          "name" => "output_tokens",
          "unit_size" => 1_000_000,
          "unit_price_usd_micros" => 4_000_000
        }
      ]
    }

    assert {:ok, cost} =
             UsageCost.calculate_usd_micros(pricing, %{
               input_tokens: 100,
               output_tokens: 20,
               input_token_details: %{cache_read: 40}
             })

    assert cost.cost_micros == 220
    assert cost.currency == "USD"

    assert cost.rounding == %{
             rule: "half_up",
             numerator: 220,
             denominator: 1
           }
  end

  test "rejects incomplete usage and invalid exact dimensions" do
    pricing = %{
      schema_version: 1,
      currency: "USD",
      rounding: "half_up",
      dimensions: [%{name: "input_tokens", unit_size: 0, unit_price_usd_micros: 1}]
    }

    valid_pricing = %{
      pricing
      | dimensions: [%{name: "input_tokens", unit_size: 1, unit_price_usd_micros: 1}]
    }

    assert {:error, :invalid_usage} = UsageCost.calculate_usd_micros(valid_pricing, %{})

    assert {:error, :invalid_pricing_dimension} =
             UsageCost.calculate_usd_micros(pricing, %{input_tokens: 1, output_tokens: 1})
  end
end
