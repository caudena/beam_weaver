defmodule BeamWeaver.RetryPolicyTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Graph.ExecutionInfo
  alias BeamWeaver.Graph.Runtime
  alias BeamWeaver.RetryPolicy
  alias BeamWeaver.TimeoutPolicy

  defmodule Predicate do
    def transient?(%Error{type: :transient}, suffix), do: suffix == "ok"
    def transient?(_error, _suffix), do: false
  end

  test "accepts native retry option names" do
    assert {:ok, policy} =
             RetryPolicy.new(%{
               "max_attempts" => 4,
               "initial_delay" => 250,
               "max_delay" => 1_500,
               "backoff" => 3.0,
               "jitter" => false,
               "retry_on" => :transient
             })

    assert policy.max_attempts == 4
    assert policy.initial_delay == 250
    assert policy.max_delay == 1_500
    assert policy.backoff == 3.0
    assert RetryPolicy.delay(policy, 2) == 750
    assert RetryPolicy.retry?(policy, Error.new(:transient, "try again"))
    refute RetryPolicy.retry?(policy, Error.new(:permanent, "stop"))
  end

  test "supports constant-delay retry policy with zero backoff" do
    assert {:ok, policy} =
             RetryPolicy.new(%{
               max_attempts: 3,
               initial_delay: 25,
               backoff: 0.0,
               jitter: false
             })

    assert policy.backoff == 0.0
    assert RetryPolicy.delay(policy, 1) == 25
    assert RetryPolicy.delay(policy, 2) == 25
  end

  test "validates delay options and caps exponential backoff" do
    assert {:error, %Error{type: :invalid_retry_policy, details: %{initial_delay: -1}}} =
             RetryPolicy.new(initial_delay: -1)

    assert {:error, %Error{type: :invalid_retry_policy, details: %{max_delay: -1}}} =
             RetryPolicy.new(max_delay: -1)

    assert {:error, %Error{type: :invalid_retry_policy, details: %{backoff: -1.0}}} =
             RetryPolicy.new(backoff: -1.0)

    assert {:error, %Error{type: :invalid_retry_policy, details: %{jitter: -1}}} =
             RetryPolicy.new(jitter: -1)

    policy =
      RetryPolicy.new!(
        max_attempts: 4,
        initial_delay: 100,
        max_delay: 250,
        backoff: 10.0,
        jitter: false
      )

    assert RetryPolicy.delay(policy, 1) == 100
    assert RetryPolicy.delay(policy, 2) == 250
    assert RetryPolicy.delay(policy, 3) == 250
  end

  test "integer jitter varies delay within the configured window" do
    policy =
      RetryPolicy.new!(
        max_attempts: 2,
        initial_delay: 100,
        backoff: 1.0,
        jitter: 25
      )

    delays = Enum.map(1..20, fn _ -> RetryPolicy.delay(policy, 1) end)

    assert Enum.all?(delays, &(&1 >= 100 and &1 <= 125))
    assert delays |> MapSet.new() |> MapSet.size() > 1
  end

  test "retry predicates cover defaults atoms lists functions and mfa predicates" do
    transient = Error.new(:transient, "try again")
    permanent = Error.new(:permanent, "stop")

    assert RetryPolicy.retry?(RetryPolicy.new!(), transient)
    refute RetryPolicy.retry?(RetryPolicy.new!(), :not_an_error)

    assert RetryPolicy.retry?(RetryPolicy.new!(retry_on: :transient), transient)
    refute RetryPolicy.retry?(RetryPolicy.new!(retry_on: :transient), permanent)

    assert RetryPolicy.retry?(
             RetryPolicy.new!(retry_on: :transient),
             Error.new(:transport_error, "Google transport request failed", %{
               reason: "%Req.TransportError{reason: :nxdomain}"
             })
           )

    assert RetryPolicy.retry?(RetryPolicy.new!(retry_on: [:transient, :rate_limit]), transient)
    refute RetryPolicy.retry?(RetryPolicy.new!(retry_on: []), transient)

    function_policy =
      RetryPolicy.new!(
        retry_on: fn
          %Error{type: :transient} -> true
          _error -> false
        end
      )

    assert RetryPolicy.retry?(function_policy, transient)
    refute RetryPolicy.retry?(function_policy, permanent)

    mfa_policy = RetryPolicy.new!(retry_on: {Predicate, :transient?, ["ok"]})
    assert RetryPolicy.retry?(mfa_policy, transient)
    refute RetryPolicy.retry?(mfa_policy, permanent)
  end

  test "rejects unknown string options without creating atoms" do
    assert {:error, %Error{type: :invalid_retry_policy} = error} =
             RetryPolicy.new(%{"beam_weaver_retry_unknown_option_for_test" => true})

    assert error.details.option =~ "beam_weaver_retry_unknown_option_for_test"
  end

  test "extracts parent checkpoint namespace from nested task namespaces" do
    assert RetryPolicy.checkpoint_parent_namespace("") == ""
    assert RetryPolicy.checkpoint_parent_namespace("node:1") == ""
    assert RetryPolicy.checkpoint_parent_namespace("node:1|child:2") == "node:1"
    assert RetryPolicy.checkpoint_parent_namespace("node:1|1|child:2") == "node:1"
    assert RetryPolicy.checkpoint_parent_namespace("node:1|1|child:2|1") == "node:1"

    assert RetryPolicy.checkpoint_parent_namespace("parent:1|1|child:1|1|node:1|1") ==
             "parent:1|1|child:1"

    assert RetryPolicy.checkpoint_parent_namespace("parent:1|1|child:1|1|node:1") ==
             "parent:1|1|child:1"
  end

  test "coerces timeout policy durations using BeamWeaver millisecond semantics" do
    assert {:ok, %TimeoutPolicy{run_timeout: 250, idle_timeout: nil, refresh_on: :auto}} =
             TimeoutPolicy.coerce(0.25)

    assert {:ok, %TimeoutPolicy{run_timeout: 500, idle_timeout: 125, refresh_on: :heartbeat}} =
             TimeoutPolicy.coerce(%{
               "run_timeout" => 500,
               "idle_timeout" => 0.125,
               "refresh_on" => "heartbeat"
             })

    policy = TimeoutPolicy.new!(run_timeout: 100)
    assert {:ok, ^policy} = TimeoutPolicy.coerce(policy)
    assert {:ok, nil} = TimeoutPolicy.coerce(nil)
    assert {:ok, nil} = TimeoutPolicy.coerce(%TimeoutPolicy{})

    assert {:error, %Error{type: :invalid_timeout_policy}} = TimeoutPolicy.coerce(0)

    assert {:error, %Error{type: :invalid_timeout_policy}} =
             TimeoutPolicy.coerce(%{refresh_on: :bad})
  end

  test "timeout policy exposes the effective supervised task budget" do
    assert {:ok, 250} = TimeoutPolicy.effective_timeout(0.25)
    assert {:ok, 100} = TimeoutPolicy.effective_timeout(run_timeout: 250, idle_timeout: 100)
    assert {:ok, 125} = TimeoutPolicy.effective_timeout(%{"idle_timeout" => 0.125})
    assert {:ok, nil} = TimeoutPolicy.effective_timeout(%TimeoutPolicy{})
  end

  test "runtime execution info is hydrated from config only when missing" do
    existing = %ExecutionInfo{checkpoint_id: "existing", task_id: "task-existing"}
    runtime = %Runtime{execution: existing}

    assert Runtime.ensure_execution_info(runtime, %{}, %{id: "ignored"}).execution == existing

    hydrated =
      Runtime.ensure_execution_info(
        %Runtime{},
        %{
          "run_id" => :run_123,
          "configurable" => %{
            "checkpoint_id" => "cp-1",
            "checkpoint_ns" => "node:task",
            "thread_id" => "thread-1"
          }
        },
        %{id: "task-fallback"}
      )

    assert hydrated.execution == %ExecutionInfo{
             checkpoint_id: "cp-1",
             checkpoint_ns: "node:task",
             task_id: "task-fallback",
             thread_id: "thread-1",
             run_id: "run_123"
           }

    assert ExecutionInfo.patch(hydrated.execution, node_attempt: 2).node_attempt == 2
  end
end
