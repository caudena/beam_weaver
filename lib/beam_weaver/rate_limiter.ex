defmodule BeamWeaver.RateLimiter do
  @moduledoc """
  Rate limiting behaviours and implementations for bounded model and tool work.
  """

  alias BeamWeaver.RateLimiter.Error
  alias BeamWeaver.RateLimiter.TokenBucket

  @type server :: GenServer.server()
  @type amount :: pos_integer()
  @type result :: :ok | {:error, Error.t()}
  @type snapshot :: %{
          capacity: number(),
          tokens: number(),
          refill_amount: number(),
          refill_interval: pos_integer(),
          queued: non_neg_integer()
        }

  @callback acquire(server(), amount(), keyword()) :: result()

  @doc """
  Starts a permanent token bucket under the BeamWeaver rate limiter supervisor.

  The bucket outlives its caller. Use `DynamicSupervisor.terminate_child/2`
  with the registered supervisor name BeamWeaver.RateLimiter.Supervisor
  and the returned PID to remove a temporary bucket. Stopping the GenServer
  directly causes the supervisor to restart it.

  For application-owned lifetime, add `BeamWeaver.RateLimiter.TokenBucket`
  to your own supervisor instead. See [Rate Limiting](rate_limiting.md).
  """
  @spec start_bucket(keyword()) :: DynamicSupervisor.on_start_child()
  def start_bucket(opts \\ []) do
    DynamicSupervisor.start_child(BeamWeaver.RateLimiter.Supervisor, {TokenBucket, opts})
  end

  @doc """
  Acquires tokens from a token-bucket limiter.
  """
  @spec acquire(server(), amount(), keyword()) :: result()
  def acquire(limiter, amount \\ 1, opts \\ []) do
    TokenBucket.acquire(limiter, amount, opts)
  end

  @doc """
  Returns a read-only token bucket snapshot for diagnostics and conformance tests.
  """
  @spec snapshot(server()) :: snapshot()
  def snapshot(limiter), do: TokenBucket.snapshot(limiter)
end
