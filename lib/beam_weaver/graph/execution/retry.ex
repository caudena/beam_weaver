defmodule BeamWeaver.Graph.Execution.Retry do
  @moduledoc false

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Graph.Execution.Telemetry
  alias BeamWeaver.RetryPolicy

  @type retry_fun :: (-> term()) | (pos_integer() -> term())

  @spec run(non_neg_integer() | RetryPolicy.t(), retry_fun()) :: term()
  def run(%RetryPolicy{} = policy, fun), do: do_run_policy(policy, 1, fun)

  def run(retries, fun) do
    attempts = max(retries, 0) + 1
    do_run(attempts, 1, fun)
  end

  defp do_run(attempts_left, attempt, fun) do
    case call_attempt(fun, attempt) do
      {:ok, value} ->
        {:ok, value}

      {:interrupted, interrupt} ->
        {:interrupted, interrupt}

      {:parent_command, command} ->
        {:parent_command, command}

      {:error, %Error{} = error} when attempts_left > 1 ->
        Telemetry.execute(:retry, %{count: 1}, %{error: error, attempt: attempt})
        do_run(attempts_left - 1, attempt + 1, fun)

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp do_run_policy(%RetryPolicy{} = policy, attempt, fun) do
    case call_attempt(fun, attempt) do
      {:ok, value} ->
        {:ok, value}

      {:interrupted, interrupt} ->
        {:interrupted, interrupt}

      {:parent_command, command} ->
        {:parent_command, command}

      {:error, %Error{} = error} ->
        if attempt < policy.max_attempts and RetryPolicy.retry?(policy, error) do
          Telemetry.execute(:retry, %{count: 1}, %{error: error, attempt: attempt})
          delay = RetryPolicy.delay(policy, attempt)
          if delay > 0, do: Process.sleep(delay)
          do_run_policy(policy, attempt + 1, fun)
        else
          {:error, error}
        end
    end
  end

  defp call_attempt(fun, attempt) when is_function(fun, 1), do: fun.(attempt)
  defp call_attempt(fun, _attempt) when is_function(fun, 0), do: fun.()
end
