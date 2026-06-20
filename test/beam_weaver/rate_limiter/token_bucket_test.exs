defmodule BeamWeaver.RateLimiter.TokenBucketTest do
  use ExUnit.Case

  alias BeamWeaver.Core.Async
  alias BeamWeaver.RateLimiter
  alias BeamWeaver.RateLimiter.Error
  alias BeamWeaver.RateLimiter.TokenBucket

  test "allows a burst up to capacity and then rejects drop-mode callers" do
    limiter = start_bucket!(capacity: 2, initial_tokens: 2, refill_interval: 1_000)

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

    assert :ok = RateLimiter.acquire(limiter, 1, timeout: 100)
  end

  test "uses native token bucket timing options" do
    limiter =
      start_bucket!(
        capacity: 2,
        refill_amount: 1,
        refill_interval: 50
      )

    assert %{
             capacity: 2,
             tokens: 0,
             refill_amount: 1,
             refill_interval: 50
           } = RateLimiter.snapshot(limiter)

    assert :ok = RateLimiter.acquire(limiter, 1, timeout: 120)
  end

  test "waits for refill instead of forcing callers to sleep outside the limiter" do
    limiter =
      start_bucket!(
        capacity: 1,
        initial_tokens: 0,
        refill_amount: 1,
        refill_interval: 30
      )

    started_at = System.monotonic_time(:millisecond)

    assert :ok = RateLimiter.acquire(limiter, 1, timeout: 200)
    assert System.monotonic_time(:millisecond) - started_at >= 20
  end

  test "async acquire returns a Task-backed handle" do
    limiter =
      start_bucket!(
        capacity: 1,
        initial_tokens: 0,
        refill_amount: 1,
        refill_interval: 25
      )

    assert :ok =
             limiter
             |> RateLimiter.async_acquire(1, timeout: 100)
             |> Async.await(200)
  end

  test "returns a tagged timeout when queued work cannot get a token in time" do
    limiter =
      start_bucket!(
        capacity: 1,
        initial_tokens: 0,
        refill_amount: 1,
        refill_interval: 1_000
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
        refill_interval: 120
      )

    caller =
      spawn(fn ->
        RateLimiter.acquire(limiter, 1, timeout: 5_000)
      end)

    Process.sleep(25)
    Process.exit(caller, :kill)
    Process.sleep(25)

    assert :ok = RateLimiter.acquire(limiter, 1, timeout: 250)
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
        refill_interval: 1_000
      )

    started_at = System.monotonic_time(:millisecond)

    assert {:error, %Error{type: :invalid_option}} =
             RateLimiter.acquire(limiter, 1, timeout: -1)

    assert System.monotonic_time(:millisecond) - started_at < 500
  end

  defp start_bucket!(opts) do
    start_supervised!({TokenBucket, opts})
  end
end
