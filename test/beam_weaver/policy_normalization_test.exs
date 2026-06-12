defmodule BeamWeaver.PolicyNormalizationTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.CachePolicy
  alias BeamWeaver.ExecutionPolicy
  alias BeamWeaver.Models.ParamPolicy
  alias BeamWeaver.RateLimitPolicy
  alias BeamWeaver.RetrievalPolicy
  alias BeamWeaver.ShellPolicy
  alias BeamWeaver.Stream.Policy, as: StreamPolicy

  test "policy structs accept string keys without creating unknown atoms" do
    unknown = "beam_weaver_policy_unknown_#{System.unique_integer([:positive])}"
    refute existing_atom?(unknown)

    assert {:ok, %ExecutionPolicy{timeout: 250}} =
             ExecutionPolicy.new(%{"timeout" => 0.25, unknown => true})

    assert {:ok, %CachePolicy{ttl: 10}} = CachePolicy.new(%{"ttl" => 10, unknown => true})

    assert {:ok, %RateLimitPolicy{amount: 2}} =
             RateLimitPolicy.new(%{"amount" => 2, unknown => true})

    assert {:ok, %RetrievalPolicy{k: 2}} = RetrievalPolicy.new(%{"k" => 2, unknown => true})

    assert {:ok, %ShellPolicy{max_output_bytes: 50}} =
             ShellPolicy.new(%{
               "allow" => ["echo "],
               "max_output_bytes" => 50,
               unknown => true
             })

    refute existing_atom?(unknown)
  end

  test "string enum normalization is allowlisted" do
    assert %ParamPolicy{mode: :warn} = ParamPolicy.new(%{"mode" => "warn"})
    assert %StreamPolicy{overflow: :drop_oldest} = StreamPolicy.new(overflow: "drop_oldest")
    assert %StreamPolicy{overflow: :block} = StreamPolicy.new(overflow: "not_a_known_mode")
  end

  test "shared policy constructor preserves bang and validation behavior" do
    assert %ExecutionPolicy{timeout: 250} = ExecutionPolicy.new!(timeout: 0.25)

    assert_raise ArgumentError, "metadata must be a map", fn ->
      ExecutionPolicy.new!(metadata: :bad)
    end

    assert {:error, %{type: :invalid_cache_policy, message: "ttl must be nil or a non-negative integer"}} =
             CachePolicy.new(ttl: -1)

    assert {:error,
            %{
              type: :invalid_rate_limit_policy,
              message: "amount must be a positive integer"
            }} = RateLimitPolicy.new(amount: 0)

    assert {:error, %{type: :invalid_retrieval_policy, message: "mmr_lambda must be between 0 and 1"}} =
             RetrievalPolicy.new(mmr_lambda: 2)
  end

  defp existing_atom?(value) do
    _atom = String.to_existing_atom(value)
    true
  rescue
    ArgumentError -> false
  end
end
