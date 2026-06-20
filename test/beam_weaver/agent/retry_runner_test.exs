defmodule BeamWeaver.Agent.Middleware.RetryRunnerTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Agent.Middleware.RetryRunner

  test "policy_opts preserves an MFA-tuple retry_on predicate" do
    mfa = {String, :contains?, ["x"]}
    result = RetryRunner.policy_opts([retry_on: mfa], [])
    assert Keyword.get(result, :retry_on) == mfa
  end

  test "policy_opts flattens a tuple of error types into a list" do
    result = RetryRunner.policy_opts([retry_on: {:timeout, :closed}], [])
    assert Keyword.get(result, :retry_on) == [:timeout, :closed]
  end
end
