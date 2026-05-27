# BeamWeaver Rate Limiting

BeamWeaver rate limiting bounds model and tool work before the runtime starts
supervised tasks.

The first implementation is an in-memory token bucket:

```elixir
{:ok, limiter} =
  BeamWeaver.RateLimiter.start_bucket(
    capacity: 10,
    refill_amount: 10,
    refill_interval: 1_000
  )

:ok = BeamWeaver.RateLimiter.acquire(limiter, 1, timeout: 5_000)
```

Callers can wait, reject immediately, or drop immediately:

```elixir
BeamWeaver.RateLimiter.acquire(limiter, 1, mode: :wait, timeout: 5_000)
BeamWeaver.RateLimiter.acquire(limiter, 1, mode: :reject)
BeamWeaver.RateLimiter.acquire(limiter, 1, mode: :drop)
```

Failures are tagged tuples:

```elixir
{:error, %BeamWeaver.RateLimiter.Error{type: :timeout}}
{:error, %BeamWeaver.RateLimiter.Error{type: :rate_limited}}
```

Queued callers are monitored. If waiting work is canceled, it is removed from the
queue and does not consume future refill capacity.

## Related Guides

- [Models](models.md#rate-limiting)
- [Fault Tolerance](fault_tolerance.md)
- [Prebuilt Middleware](prebuilt_middleware.md#model-and-tool-call-limits)
- [Going To Production](going_to_production.md)
