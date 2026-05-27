defmodule BeamWeaver.Graph.Execution.Options do
  @moduledoc false

  @spec normalize_config(keyword() | map()) :: map()
  def normalize_config(config) when is_list(config), do: Map.new(config)
  def normalize_config(config) when is_map(config), do: config

  @spec normalize_failure_policy(term()) :: :panic | :proceed
  def normalize_failure_policy(policy) when policy in [:panic, :proceed], do: policy
  def normalize_failure_policy("panic"), do: :panic
  def normalize_failure_policy("proceed"), do: :proceed
  def normalize_failure_policy(_policy), do: :panic

  @spec normalize_timeout(term()) :: non_neg_integer() | :infinity
  def normalize_timeout(:infinity), do: :infinity
  def normalize_timeout(nil), do: :infinity

  def normalize_timeout(timeout) when is_float(timeout) and timeout >= 0,
    do: round(timeout * 1_000)

  def normalize_timeout(timeout) when is_integer(timeout) and timeout >= 0, do: timeout
  def normalize_timeout(_timeout), do: :infinity
end
