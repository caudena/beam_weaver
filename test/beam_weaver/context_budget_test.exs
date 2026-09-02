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

  test "fails closed for invalid shared-limit reservations" do
    profile = %Profile{
      context_limit_kind: :shared_input_output,
      max_context_tokens: 10_000,
      provider_reserved_tokens: 100
    }

    assert {:error, %{type: :unknown_context_limit}} =
             ContextBudget.effective_input_limit(profile, requested_max_output_tokens: "1_000")

    assert {:error, %{type: :unknown_context_limit}} =
             ContextBudget.effective_input_limit(%{profile | provider_reserved_tokens: "100"})
  end

  test "local tokenizer accounting applies margin, protocol reserve, and provider usage floor" do
    profile = %Profile{max_input_tokens: 10_000, tokenizer: :static}

    assert {:ok, budget} =
             ContextBudget.new(profile, "one two three four",
               accounting_method: :local_tokenizer_v1,
               reported_input_tokens: 300,
               profile_hash: String.duplicate("a", 64),
               categories: %{"system" => 3, "memory_history" => 1}
             )

    assert budget.method == :local_tokenizer_v1
    assert budget.estimated_tokens == 300
    assert budget.profile_hash == String.duplicate("a", 64)
    assert budget.category_bytes == %{"system" => 3, "memory_history" => 1}
    assert Enum.sum(Map.values(budget.categories)) == budget.estimated_tokens
    assert budget.categories["memory_history"] > 0
  end

  test "unsupported local accounting falls back to conservative UTF-8 bytes" do
    profile = %Profile{max_input_tokens: 10_000, tokenizer: nil}
    request = "four UTF-8 bytes"

    assert {:ok, budget} =
             ContextBudget.new(profile, request, accounting_method: :local_tokenizer_v1)

    assert budget.method == :conservative_utf8
    assert budget.estimated_tokens == byte_size(request)
  end

  test "missing compatible provider usage contributes no lower bound" do
    profile = %Profile{max_input_tokens: 10_000}

    assert {:ok, budget} =
             ContextBudget.new(profile, "hello", reported_input_tokens: nil)

    assert budget.estimated_tokens == 5
  end

  test "string provider overhead category remains canonical and receives the residual" do
    profile = %Profile{max_input_tokens: 100_000}

    assert {:ok, budget} =
             ContextBudget.new(profile, "request", categories: %{"system" => 3, "provider_overhead" => 4})

    assert Map.has_key?(budget.categories, "provider_overhead")
    refute Map.has_key?(budget.categories, :provider_overhead)
    assert Enum.sum(Map.values(budget.categories)) == budget.estimated_tokens
    assert {:ok, _encoded} = BeamWeaver.Compaction.Canonical.encode(budget.categories)
  end

  test "same-epoch reported usage adds only exact and append-compatible component deltas" do
    profile = %Profile{max_input_tokens: 100_000}
    unchanged = String.duplicate("a", 64)
    first = String.duplicate("b", 64)
    second = String.duplicate("c", 64)

    baseline = %{
      "version" => 2,
      "input_tokens" => 1_000,
      "components" => %{
        "system" => %{"kind" => "exact", "bytes" => 400, "hash" => unchanged},
        "history" => %{
          "kind" => "append",
          "items" => [%{"id" => "one", "hash" => first, "bytes" => 100}]
        }
      }
    }

    current = %{
      "system" => %{"kind" => "exact", "bytes" => 400, "hash" => unchanged},
      "history" => %{
        "kind" => "append",
        "items" => [
          %{"id" => "one", "hash" => first, "bytes" => 100},
          %{"id" => "two", "hash" => second, "bytes" => 25}
        ]
      }
    }

    assert {:ok, budget} =
             ContextBudget.new(profile, String.duplicate("x", 10_000),
               categories: %{"system" => 400, "history" => 125},
               reported_usage_baseline: baseline,
               component_descriptors: current
             )

    assert budget.method == :reported_usage_delta_v2
    assert budget.version == 2
    assert budget.baseline_input_tokens == 1_000
    assert budget.delta_tokens == 25
    assert budget.estimated_tokens == 1_025
  end

  test "changed, shortened, and reordered components charge their full current bytes" do
    profile = %Profile{max_input_tokens: 100_000}
    a = String.duplicate("a", 64)
    b = String.duplicate("b", 64)
    c = String.duplicate("c", 64)

    baseline = %{
      version: 2,
      input_tokens: 500,
      components: %{
        "system" => %{kind: :exact, bytes: 10, hash: a},
        "history" => %{
          kind: :append,
          items: [
            %{id: "one", hash: a, bytes: 10},
            %{id: "two", hash: b, bytes: 20}
          ]
        }
      }
    }

    current = %{
      "system" => %{kind: :exact, bytes: 30, hash: c},
      "history" => %{kind: :append, items: [%{id: "two", hash: b, bytes: 20}]}
    }

    assert {:ok, budget} =
             ContextBudget.new(profile, "request",
               categories: %{"system" => 30, "history" => 20},
               reported_usage_baseline: baseline,
               component_descriptors: current
             )

    assert budget.estimated_tokens == 550
    assert budget.delta_tokens == 50
  end

  test "malformed or legacy baselines retain whole-request conservative accounting" do
    profile = %Profile{max_input_tokens: 100_000}

    descriptor = %{
      "system" => %{
        "kind" => "exact",
        "bytes" => 4,
        "hash" => String.duplicate("a", 64)
      }
    }

    for baseline <- [nil, %{"version" => 1}, %{"version" => 2, "input_tokens" => -1}] do
      assert {:ok, budget} =
               ContextBudget.new(profile, String.duplicate("x", 1_000),
                 reported_input_tokens: 100,
                 reported_usage_baseline: baseline,
                 component_descriptors: descriptor
               )

      assert budget.method == :conservative_utf8
      assert budget.version == 1
      assert budget.estimated_tokens == 1_000
    end
  end

  test "incompatible component sets and duplicate append identities fall back safely" do
    profile = %Profile{max_input_tokens: 100_000}
    hash = String.duplicate("a", 64)

    baseline = %{
      version: 2,
      input_tokens: 100,
      components: %{
        system: %{kind: :exact, bytes: 4, hash: hash},
        history: %{kind: :append, items: [%{id: "one", hash: hash, bytes: 3}]}
      }
    }

    incompatible = %{
      "system" => %{kind: :exact, bytes: 4, hash: hash}
    }

    duplicate_identity = %{
      "system" => %{kind: :exact, bytes: 4, hash: hash},
      "history" => %{
        kind: :append,
        items: [
          %{id: "one", hash: hash, bytes: 3},
          %{id: "one", hash: hash, bytes: 3}
        ]
      }
    }

    for current <- [incompatible, duplicate_identity] do
      assert {:ok, budget} =
               ContextBudget.new(profile, String.duplicate("x", 1_000),
                 reported_usage_baseline: baseline,
                 component_descriptors: current
               )

      assert budget.method == :conservative_utf8
      assert budget.version == 1
      assert budget.estimated_tokens == 1_000
    end
  end

  test "same hashes with inconsistent byte counts are charged instead of treated as exact" do
    profile = %Profile{max_input_tokens: 100_000}
    hash = String.duplicate("a", 64)

    baseline = %{
      version: 2,
      input_tokens: 100,
      components: %{
        system: %{kind: :exact, bytes: 4, hash: hash},
        history: %{kind: :append, items: [%{id: "one", hash: hash, bytes: 3}]}
      }
    }

    current = %{
      "system" => %{kind: :exact, bytes: 7, hash: hash},
      "history" => %{kind: :append, items: [%{id: "one", hash: hash, bytes: 5}]}
    }

    assert {:ok, budget} =
             ContextBudget.new(profile, "request",
               reported_usage_baseline: baseline,
               component_descriptors: current
             )

    assert budget.method == :reported_usage_delta_v2
    assert budget.delta_tokens == 12
    assert budget.estimated_tokens == 112
  end
end
