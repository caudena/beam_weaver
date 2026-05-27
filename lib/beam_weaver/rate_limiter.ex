defmodule BeamWeaver.RateLimiter do
  @moduledoc """
  Rate limiting behaviours and implementations for bounded model and tool work.
  """

  alias BeamWeaver.Core.Async
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
  Starts a token bucket under the BeamWeaver rate limiter supervisor.
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
  Starts an async token acquisition.
  """
  @spec async_acquire(server(), amount(), keyword()) :: Async.handle()
  def async_acquire(limiter, amount \\ 1, opts \\ []) do
    Async.run_call(opts, &acquire(limiter, amount, &1))
  end

  @doc """
  Returns a read-only token bucket snapshot for diagnostics and conformance tests.
  """
  @spec snapshot(server()) :: snapshot()
  def snapshot(limiter), do: TokenBucket.snapshot(limiter)
end
