defmodule BeamWeaver.Compaction.Policy do
  @moduledoc "Validated policy for portable or provider-native compaction."

  alias BeamWeaver.Core.Error

  @fields [
    :version,
    :enabled,
    :mode,
    :model,
    :trigger_ratio,
    :prune_release_ratio,
    :post_compaction_target_ratio,
    :recent_tail_ratio,
    :recent_tail_min_tokens,
    :recent_tail_max_tokens,
    :summary_output_ratio,
    :summary_output_min_tokens,
    :summary_output_max_tokens,
    :semantic_max_bytes,
    :minimum_prune_reclaim_tokens,
    :minimum_total_reclaim_tokens,
    :minimum_total_reclaim_ratio,
    :maximum_auto_compactions_per_root_turn,
    :minimum_new_tokens_before_recompact,
    :maximum_schema_repairs,
    :maximum_overflow_retries,
    :maximum_hierarchical_summary_calls,
    :provider_timeout_ms
  ]

  defstruct version: 1,
            enabled: true,
            mode: :portable,
            model: :current_task_model,
            trigger_ratio: 0.85,
            prune_release_ratio: 0.75,
            post_compaction_target_ratio: 0.70,
            recent_tail_ratio: 0.10,
            recent_tail_min_tokens: 8_000,
            recent_tail_max_tokens: 32_000,
            summary_output_ratio: 0.02,
            summary_output_min_tokens: 4_096,
            summary_output_max_tokens: 16_384,
            semantic_max_bytes: 131_072,
            minimum_prune_reclaim_tokens: 8_192,
            minimum_total_reclaim_tokens: 8_192,
            minimum_total_reclaim_ratio: 0.15,
            maximum_auto_compactions_per_root_turn: 3,
            minimum_new_tokens_before_recompact: 8_192,
            maximum_schema_repairs: 1,
            maximum_overflow_retries: 1,
            maximum_hierarchical_summary_calls: 3,
            provider_timeout_ms: 300_000

  @type t :: %__MODULE__{}

  @spec new(map() | keyword() | t()) :: {:ok, t()} | {:error, Error.t()}
  def new(attrs \\ %{})
  def new(%__MODULE__{} = policy), do: validate(policy)
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(%{} = attrs) do
    attrs = normalize_keys(attrs)
    unknown = Map.keys(attrs) -- @fields

    if unknown == [] do
      __MODULE__ |> struct(attrs) |> validate()
    else
      {:error, Error.new(:invalid_compaction_policy, "unknown policy fields", %{fields: unknown})}
    end
  end

  def new(_attrs), do: {:error, Error.new(:invalid_compaction_policy, "policy must be a map")}

  @spec validate(t()) :: {:ok, t()} | {:error, Error.t()}
  def validate(%__MODULE__{} = policy) do
    with true <- policy.version == 1,
         true <- is_boolean(policy.enabled),
         true <- policy.mode in [:portable, :native],
         :ok <- ratios(policy),
         :ok <- ranges(policy),
         :ok <- counts(policy) do
      {:ok, policy}
    else
      false -> {:error, Error.new(:invalid_compaction_policy, "compaction policy is invalid")}
      {:error, _error} = error -> error
    end
  end

  defp ratios(policy) do
    values = [
      policy.trigger_ratio,
      policy.prune_release_ratio,
      policy.post_compaction_target_ratio,
      policy.recent_tail_ratio,
      policy.summary_output_ratio,
      policy.minimum_total_reclaim_ratio
    ]

    if Enum.all?(values, &(is_number(&1) and &1 > 0 and &1 < 1)) and
         policy.prune_release_ratio < policy.trigger_ratio and
         policy.post_compaction_target_ratio <= policy.prune_release_ratio,
       do: :ok,
       else: {:error, Error.new(:invalid_compaction_policy, "compaction ratios are invalid")}
  end

  defp ranges(policy) do
    if positive_order?(policy.recent_tail_min_tokens, policy.recent_tail_max_tokens) and
         positive_order?(policy.summary_output_min_tokens, policy.summary_output_max_tokens),
       do: :ok,
       else: {:error, Error.new(:invalid_compaction_policy, "compaction ranges are invalid")}
  end

  defp counts(policy) do
    values = [
      policy.semantic_max_bytes,
      policy.minimum_prune_reclaim_tokens,
      policy.minimum_total_reclaim_tokens,
      policy.maximum_auto_compactions_per_root_turn,
      policy.minimum_new_tokens_before_recompact,
      policy.maximum_schema_repairs,
      policy.maximum_overflow_retries,
      policy.maximum_hierarchical_summary_calls,
      policy.provider_timeout_ms
    ]

    if Enum.all?(values, &(is_integer(&1) and &1 > 0)),
      do: :ok,
      else: {:error, Error.new(:invalid_compaction_policy, "compaction limits must be positive integers")}
  end

  defp positive_order?(minimum, maximum),
    do: is_integer(minimum) and minimum > 0 and is_integer(maximum) and maximum >= minimum

  defp normalize_keys(attrs) do
    Map.new(attrs, fn
      {key, value} when is_binary(key) ->
        atom = Enum.find(@fields, &(Atom.to_string(&1) == key))
        {atom || key, value}

      pair ->
        pair
    end)
  end
end
