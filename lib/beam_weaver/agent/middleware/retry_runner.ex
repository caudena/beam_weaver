defmodule BeamWeaver.Agent.Middleware.RetryRunner do
  @moduledoc false

  alias BeamWeaver.Core.Error
  alias BeamWeaver.RetryPolicy

  @spec run(RetryPolicy.t(), (-> term()), keyword()) :: term()
  def run(%RetryPolicy{} = policy, fun, opts) when is_function(fun, 0) do
    prefix = Keyword.get(opts, :telemetry_prefix)

    on_retry = fn attempt, error ->
      if prefix, do: :telemetry.execute(prefix ++ [:retry], %{attempt: attempt}, %{error: error})
    end

    RetryPolicy.run(policy, fn -> normalize_result(fun.()) end,
      attempt: Keyword.get(opts, :attempt, 1),
      on_retry: on_retry
    )
  end

  # Like `run/3`, and also returns how many attempts it made: fewer than the
  # policy's `max_attempts` when an error isn't one it retries.
  @spec run_counting(RetryPolicy.t(), (-> term()), keyword()) :: {term(), pos_integer()}
  def run_counting(%RetryPolicy{} = policy, fun, opts) when is_function(fun, 0) do
    attempts = :counters.new(1, [])

    result =
      run(
        policy,
        fn ->
          :counters.add(attempts, 1, 1)
          fun.()
        end,
        opts
      )

    {result, :counters.get(attempts, 1)}
  end

  defp normalize_result({:error, error}), do: {:error, normalize_error(error)}
  defp normalize_result(result), do: result

  @spec normalize_error(term()) :: Error.t()
  defp normalize_error(%Error{} = error), do: error

  defp normalize_error(%{type: type, message: message, details: details})
       when is_atom(type) and is_binary(message) and is_map(details) do
    Error.new(type, message, details)
  end

  defp normalize_error(%{type: type, message: message})
       when is_atom(type) and is_binary(message) do
    Error.new(type, message, %{})
  end

  defp normalize_error(error) do
    Error.new(:middleware_error, "middleware target returned an error", %{error: inspect(error)})
  end

  @doc false
  def policy_opts(opts, drop_keys) when is_list(opts) and is_list(drop_keys) do
    opts
    |> Keyword.get(:policy, Keyword.drop(opts, drop_keys))
    |> normalize_policy_opts()
  end

  defp normalize_policy_opts(%RetryPolicy{} = policy), do: policy

  defp normalize_policy_opts(opts) when is_list(opts) do
    opts
    |> maybe_translate_max_retries()
    |> Keyword.update(:retry_on, :error, &normalize_retry_on/1)
  end

  defp normalize_policy_opts(opts) when is_map(opts) do
    opts
    |> Map.to_list()
    |> normalize_policy_opts()
  end

  defp maybe_translate_max_retries(opts) do
    case Keyword.fetch(opts, :max_retries) do
      {:ok, retries} when is_integer(retries) and retries >= 0 ->
        opts
        |> Keyword.delete(:max_retries)
        |> Keyword.put_new(:max_attempts, retries + 1)

      {:ok, retries} ->
        raise ArgumentError,
              "max_retries must be a non-negative integer, got: #{inspect(retries)}"

      :error ->
        opts
    end
  end

  defp normalize_retry_on({m, f, a}) when is_atom(m) and is_atom(f) and is_list(a), do: {m, f, a}
  defp normalize_retry_on(value) when is_tuple(value), do: Tuple.to_list(value)
  defp normalize_retry_on(value), do: value
end
