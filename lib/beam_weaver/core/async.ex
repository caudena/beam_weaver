defmodule BeamWeaver.Core.Async do
  @moduledoc """
  Task-backed async helpers for provider public APIs.
  """

  @typedoc "Async work handle returned by BeamWeaver async APIs."
  @type handle :: Task.t()

  @doc """
  Starts async work, optionally under a caller-provided task supervisor.
  """
  @spec run((-> term()), keyword()) :: handle()
  def run(fun, opts \\ []) when is_function(fun, 0) do
    case Keyword.get(opts, :task_supervisor) do
      nil ->
        Task.async(fun)

      supervisor ->
        Task.Supervisor.async_nolink(supervisor, fun)
    end
  end

  @doc """
  Splits async runtime options from options passed to the wrapped call.
  """
  @spec split_opts(keyword()) :: {keyword(), keyword()}
  def split_opts(opts) when is_list(opts) do
    Keyword.split(opts, [:task_supervisor])
  end

  @doc """
  Starts async work for a function that expects call options.
  """
  @spec run_call(keyword(), (keyword() -> term())) :: handle()
  def run_call(opts, fun) when is_list(opts) and is_function(fun, 1) do
    {async_opts, call_opts} = split_opts(opts)
    run(fn -> fun.(call_opts) end, async_opts)
  end

  @doc """
  Awaits an async handle.
  """
  @spec await(handle(), timeout()) :: term()
  def await(%Task{} = task, timeout \\ 5_000) do
    Task.await(task, timeout)
  end

  @doc """
  Yields an async handle without forcing completion.
  """
  @spec yield(handle(), timeout()) :: {:ok, term()} | {:exit, term()} | nil
  def yield(%Task{} = task, timeout \\ 0) do
    Task.yield(task, timeout)
  end

  @doc """
  Cancels an async handle and returns the shutdown result.
  """
  @spec cancel(handle(), timeout()) :: {:ok, term()} | {:exit, term()} | nil
  def cancel(%Task{} = task, timeout \\ 5_000) do
    Task.shutdown(task, timeout)
  end

  @doc """
  Starts ordered async work for each input.
  """
  @spec batch([term()], (term() -> term()), keyword()) :: [handle()]
  def batch(inputs, fun, opts \\ []) when is_list(inputs) and is_function(fun, 1) do
    Enum.map(inputs, fn input -> run(fn -> fun.(input) end, opts) end)
  end

  @doc """
  Starts ordered async work for each input with shared call options.
  """
  @spec batch_call([term()], keyword(), (term(), keyword() -> term())) :: [handle()]
  def batch_call(inputs, opts, fun)
      when is_list(inputs) and is_list(opts) and is_function(fun, 2) do
    {async_opts, call_opts} = split_opts(opts)
    batch(inputs, fn input -> fun.(input, call_opts) end, async_opts)
  end

  @doc """
  Awaits ordered async batch handles.
  """
  @spec await_batch([handle()], timeout()) :: [term()]
  def await_batch(tasks, timeout \\ 5_000) when is_list(tasks) do
    Enum.map(tasks, &await(&1, timeout))
  end
end
