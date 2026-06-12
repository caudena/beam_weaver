defmodule BeamWeaver.Agent.Middleware.RetryRunner do
  @moduledoc false

  alias BeamWeaver.Core.Error
  alias BeamWeaver.RetryPolicy

  @spec run(RetryPolicy.t(), (-> term()), keyword()) :: term()
  def run(%RetryPolicy{} = policy, fun, opts \\ []) when is_function(fun, 0) do
    retry(policy, Keyword.get(opts, :attempt, 1), fun, Keyword.get(opts, :telemetry_prefix))
  end

  @spec normalize_error(term()) :: Error.t()
  def normalize_error(%Error{} = error), do: error

  def normalize_error(%{type: type, message: message, details: details})
      when is_atom(type) and is_binary(message) and is_map(details) do
    Error.new(type, message, details)
  end

  def normalize_error(%{type: type, message: message})
      when is_atom(type) and is_binary(message) do
    Error.new(type, message, %{})
  end

  def normalize_error(error) do
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

  defp normalize_retry_on(value) when is_tuple(value), do: Tuple.to_list(value)
  defp normalize_retry_on(value), do: value

  defp retry(%RetryPolicy{} = policy, attempt, fun, telemetry_prefix) do
    case fun.() do
      {:error, error} ->
        normalized = normalize_error(error)

        if attempt < policy.max_attempts and RetryPolicy.retry?(policy, normalized) do
          emit_retry(telemetry_prefix, attempt, normalized)
          sleep(policy, attempt)
          retry(policy, attempt + 1, fun, telemetry_prefix)
        else
          {:error, normalized}
        end

      other ->
        other
    end
  end

  defp emit_retry(nil, _attempt, _error), do: :ok

  defp emit_retry(prefix, attempt, error) do
    :telemetry.execute(prefix ++ [:retry], %{attempt: attempt}, %{error: error})
  end

  defp sleep(%RetryPolicy{} = policy, attempt) do
    delay = RetryPolicy.delay(policy, attempt)
    if delay > 0, do: Process.sleep(delay)
  end
end
