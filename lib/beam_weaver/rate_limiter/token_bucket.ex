defmodule BeamWeaver.RateLimiter.TokenBucket do
  @moduledoc """
  In-memory token-bucket rate limiter.

  The bucket supports immediate rejection, queued waiting with explicit timeout,
  burst capacity, periodic refill, and queued-caller cancellation.

  As a child of a supervisor, a bucket's child id is its `:name`, so several
  named buckets can share one supervisor. Pass `:id` to choose another id.
  """

  use GenServer

  alias BeamWeaver.RateLimiter.Error

  defstruct [
    :capacity,
    :refill_amount,
    :refill_interval,
    :tick_ref,
    tokens: 0,
    queue: :queue.new()
  ]

  @type t :: %__MODULE__{
          capacity: number(),
          tokens: number(),
          refill_amount: number(),
          refill_interval: pos_integer(),
          tick_ref: reference() | nil,
          queue: :queue.queue()
        }

  @type mode :: :wait | :drop | :reject

  @doc """
  Starts a token bucket.

  Options:

  - `:name` - optional registered process name.
  - `:capacity` - maximum tokens in the bucket.
  - `:initial_tokens` - starting tokens, defaults to `0` to avoid an initial burst.
  - `:refill_amount` - tokens added every interval, defaults to capacity.
  - `:refill_interval` - refill interval in milliseconds, defaults to 1000.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name])
  end

  @doc false
  def child_spec(opts) do
    %{
      id: Keyword.get_lazy(opts, :id, fn -> Keyword.get(opts, :name, __MODULE__) end),
      start: {__MODULE__, :start_link, [Keyword.delete(opts, :id)]}
    }
  end

  @spec acquire(GenServer.server(), pos_integer(), keyword()) :: :ok | {:error, Error.t()}
  def acquire(limiter, amount \\ 1, opts \\ []) do
    GenServer.call(limiter, {:acquire, amount, opts}, :infinity)
  end

  @doc """
  Returns the current bucket counters without mutating the limiter.
  """
  @spec snapshot(GenServer.server()) :: map()
  def snapshot(limiter) do
    GenServer.call(limiter, :snapshot)
  end

  @impl true
  def init(opts) do
    capacity = Keyword.get(opts, :capacity, 1)
    refill_interval = Keyword.get(opts, :refill_interval, 1_000)
    refill_amount = Keyword.get(opts, :refill_amount, capacity)
    initial_tokens = Keyword.get(opts, :initial_tokens, 0)

    with :ok <- positive_number(:capacity, capacity),
         :ok <- positive_number(:refill_amount, refill_amount),
         :ok <- positive_integer(:refill_interval, refill_interval),
         :ok <- non_negative_number(:initial_tokens, initial_tokens) do
      state = %__MODULE__{
        capacity: capacity,
        tokens: min(initial_tokens, capacity),
        refill_amount: refill_amount,
        refill_interval: refill_interval
      }

      {:ok, schedule_refill(state)}
    else
      {:error, %Error{} = error} -> {:stop, error}
    end
  end

  @impl true
  def handle_call({:acquire, amount, opts}, from, state) do
    mode = Keyword.get(opts, :mode, :wait)
    timeout = Keyword.get(opts, :timeout, 5_000)

    cond do
      mode not in [:wait, :drop, :reject] ->
        {:reply, {:error, Error.new(:invalid_mode, "mode must be :wait, :drop, or :reject")}, state}

      timeout != :infinity and (not is_integer(timeout) or timeout < 0) ->
        {:reply, {:error, Error.new(:invalid_option, "timeout must be a non-negative integer or :infinity")}, state}

      not is_integer(amount) or amount <= 0 ->
        {:reply, {:error, Error.new(:invalid_amount, "amount must be a positive integer")}, state}

      amount > state.capacity ->
        {:reply,
         {:error,
          Error.new(:amount_exceeds_capacity, "amount exceeds bucket capacity", %{
            amount: amount,
            capacity: state.capacity
          })}, state}

      amount <= state.tokens ->
        {:reply, :ok, %{state | tokens: state.tokens - amount}}

      mode in [:drop, :reject] ->
        {:reply, {:error, Error.new(:rate_limited, "not enough tokens available")}, state}

      mode == :wait ->
        {:noreply, enqueue_waiter(state, from, amount, timeout)}
    end
  end

  def handle_call(:snapshot, _from, state) do
    {:reply,
     %{
       capacity: state.capacity,
       tokens: state.tokens,
       refill_amount: state.refill_amount,
       refill_interval: state.refill_interval,
       queued: :queue.len(state.queue)
     }, state}
  end

  @impl true
  def handle_info(:refill, state) do
    state = %{state | tokens: min(state.capacity, state.tokens + state.refill_amount)}
    {:noreply, state |> drain_queue() |> schedule_refill()}
  end

  def handle_info({:acquire_timeout, id}, state) do
    {waiter, queue} = pop_waiter(state.queue, &(&1.id == id))

    if waiter do
      Process.demonitor(waiter.monitor, [:flush])

      GenServer.reply(
        waiter.from,
        {:error, Error.new(:timeout, "timed out waiting for rate limit token")}
      )
    end

    {:noreply, %{state | queue: queue}}
  end

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    {waiter, queue} = pop_waiter(state.queue, &(&1.monitor == monitor))

    if waiter && waiter.timer do
      Process.cancel_timer(waiter.timer)
    end

    {:noreply, %{state | queue: queue}}
  end

  defp enqueue_waiter(state, {pid, _tag} = from, amount, timeout) do
    id = make_ref()
    timer = if timeout != :infinity, do: Process.send_after(self(), {:acquire_timeout, id}, timeout)
    waiter = %{id: id, from: from, amount: amount, monitor: Process.monitor(pid), timer: timer}
    %{state | queue: :queue.in(waiter, state.queue)}
  end

  defp drain_queue(state) do
    case :queue.out(state.queue) do
      {{:value, waiter}, queue} when waiter.amount <= state.tokens ->
        Process.demonitor(waiter.monitor, [:flush])
        if waiter.timer, do: Process.cancel_timer(waiter.timer)
        GenServer.reply(waiter.from, :ok)

        drain_queue(%{state | queue: queue, tokens: state.tokens - waiter.amount})

      _empty_or_blocked ->
        state
    end
  end

  defp pop_waiter(queue, matcher) do
    {matches, remaining} =
      queue
      |> :queue.to_list()
      |> Enum.split_with(matcher)

    {List.first(matches), :queue.from_list(remaining)}
  end

  defp schedule_refill(%__MODULE__{} = state) do
    if state.tick_ref do
      Process.cancel_timer(state.tick_ref)
    end

    %{state | tick_ref: Process.send_after(self(), :refill, state.refill_interval)}
  end

  defp positive_integer(_name, value) when is_integer(value) and value > 0, do: :ok
  defp positive_integer(name, value), do: invalid_option(name, value, "a positive integer")

  defp positive_number(_name, value) when is_number(value) and value > 0, do: :ok
  defp positive_number(name, value), do: invalid_option(name, value, "a positive number")

  defp non_negative_number(_name, value) when is_number(value) and value >= 0, do: :ok
  defp non_negative_number(name, value), do: invalid_option(name, value, "a non-negative number")

  defp invalid_option(name, value, expected),
    do: {:error, Error.new(:invalid_option, "#{name} must be #{expected}", %{value: value})}
end
