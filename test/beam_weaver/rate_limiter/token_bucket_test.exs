defmodule BeamWeaver.RateLimiter.TokenBucketTest do
  use ExUnit.Case

  import BeamWeaver.TestSupport.Eventually

  alias BeamWeaver.RateLimiter
  alias BeamWeaver.RateLimiter.Error
  alias BeamWeaver.RateLimiter.TokenBucket

  test "allows a burst up to capacity and then rejects drop-mode callers" do
    limiter = start_bucket!(capacity: 2, initial_tokens: 2, refill_interval: 60_000)

    assert :ok = RateLimiter.acquire(limiter)
    assert :ok = RateLimiter.acquire(limiter)

    assert {:error, %Error{type: :rate_limited}} =
             RateLimiter.acquire(limiter, 1, mode: :drop)
  end

  test "starts empty by default and exposes a diagnostic snapshot" do
    limiter = start_bucket!(capacity: 1, refill_amount: 1, refill_interval: 30)

    assert %{
             capacity: 1,
             tokens: 0,
             refill_amount: 1,
             refill_interval: 30,
             queued: 0
           } = RateLimiter.snapshot(limiter)

    assert {:error, %Error{type: :rate_limited}} =
             RateLimiter.acquire(limiter, 1, mode: :drop)

    assert :ok = RateLimiter.acquire(limiter, 1, timeout: 5_000)
  end

  test "waits for refill instead of forcing callers to sleep outside the limiter" do
    started_at = System.monotonic_time(:millisecond)

    limiter =
      start_bucket!(
        capacity: 1,
        initial_tokens: 0,
        refill_amount: 1,
        refill_interval: 30
      )

    assert :ok = RateLimiter.acquire(limiter, 1, timeout: 5_000)
    assert System.monotonic_time(:millisecond) - started_at >= 20
  end

  test "returns a tagged timeout when queued work cannot get a token in time" do
    limiter =
      start_bucket!(
        capacity: 1,
        initial_tokens: 0,
        refill_amount: 1,
        refill_interval: 60_000
      )

    assert {:error, %Error{type: :timeout, message: message}} =
             RateLimiter.acquire(limiter, 1, timeout: 10)

    assert message =~ "timed out"
  end

  test "canceled queued callers do not consume future refill capacity" do
    limiter =
      start_bucket!(
        capacity: 1,
        initial_tokens: 0,
        refill_amount: 1,
        refill_interval: 60_000
      )

    caller = spawn(fn -> RateLimiter.acquire(limiter, 1, timeout: 60_000) end)
    assert eventually(fn -> RateLimiter.snapshot(limiter).queued == 1 end)

    # Neither a refill nor the caller's own timeout comes during the test, so
    # only its exit can empty the queue: the next refill stays in the bucket.
    Process.exit(caller, :kill)
    assert eventually(fn -> RateLimiter.snapshot(limiter).queued == 0 end)
    assert %{tokens: 0} = RateLimiter.snapshot(limiter)
  end

  test "rejects impossible requests with tagged errors" do
    limiter = start_bucket!(capacity: 1)

    assert {:error, %Error{type: :invalid_amount}} = RateLimiter.acquire(limiter, 0)

    assert {:error, %Error{type: :amount_exceeds_capacity, details: details}} =
             RateLimiter.acquire(limiter, 2)

    assert details == %{amount: 2, capacity: 1}
  end

  test "starts named buckets under the BeamWeaver rate limiter supervisor" do
    name = :"bucket_#{System.unique_integer([:positive])}"

    assert {:ok, pid} =
             RateLimiter.start_bucket(
               name: name,
               capacity: 1,
               initial_tokens: 1,
               refill_interval: 1_000
             )

    assert Process.alive?(pid)
    assert :ok = RateLimiter.acquire(name)
  end

  test "rejects an invalid mode even when tokens are available" do
    limiter = start_bucket!(capacity: 2, initial_tokens: 2, refill_interval: 1_000)

    assert {:error, %Error{type: :invalid_mode}} =
             RateLimiter.acquire(limiter, 1, mode: :bogus)

    assert %{tokens: 2} = RateLimiter.snapshot(limiter)
  end

  test "rejects a negative timeout instead of silently waiting" do
    limiter =
      start_bucket!(
        capacity: 1,
        initial_tokens: 0,
        refill_amount: 1,
        refill_interval: 60_000
      )

    started_at = System.monotonic_time(:millisecond)

    assert {:error, %Error{type: :invalid_option}} =
             RateLimiter.acquire(limiter, 1, timeout: -1)

    # Waiting would mean waiting for the next refill, a minute away.
    assert System.monotonic_time(:millisecond) - started_at < 5_000
  end

  test "named buckets share one supervisor without explicit child ids" do
    model = :"model_limiter_#{System.unique_integer([:positive])}"
    help_center = :"help_center_limiter_#{System.unique_integer([:positive])}"

    children = [
      {TokenBucket, name: model, capacity: 2, initial_tokens: 2},
      {TokenBucket, name: help_center, capacity: 1, initial_tokens: 1}
    ]

    supervisor =
      start_supervised!(%{
        id: :buckets,
        start: {Supervisor, :start_link, [children, [strategy: :one_for_one]]},
        type: :supervisor
      })

    assert supervisor |> Supervisor.which_children() |> Enum.map(&elem(&1, 0)) |> Enum.sort() ==
             Enum.sort([model, help_center])

    assert :ok = RateLimiter.acquire(model, 2)
    assert :ok = RateLimiter.acquire(help_center)

    assert %{id: :limiter} = Supervisor.child_spec({TokenBucket, name: model, id: :limiter}, [])
  end

  defp start_bucket!(opts) do
    start_supervised!({TokenBucket, opts})
  end
end
