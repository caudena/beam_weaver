defmodule BeamWeaver.Compaction.State do
  @moduledoc "Bounded lane-local circuit state for automatic compaction."

  alias BeamWeaver.Compaction.Policy
  alias BeamWeaver.Core.Error

  @fields [
    :successful_auto_compactions,
    :last_compaction_lane_event_ordinal,
    :last_compaction_tokens_after,
    :new_tokens_since_compaction,
    :overflow_retry_used,
    :consecutive_ineffective_compactions,
    :cancellation_pending
  ]
  @field_names Map.new(@fields, &{Atom.to_string(&1), &1})

  defstruct successful_auto_compactions: 0,
            last_compaction_lane_event_ordinal: nil,
            last_compaction_tokens_after: nil,
            new_tokens_since_compaction: 0,
            overflow_retry_used: false,
            consecutive_ineffective_compactions: 0,
            cancellation_pending: false

  @type t :: %__MODULE__{}

  @spec new(map() | t()) :: {:ok, t()} | {:error, Error.t()}
  def new(%__MODULE__{} = state), do: validate(state)

  def new(%{} = attrs) do
    with {:ok, attrs} <- normalize_keys(attrs) do
      if Enum.all?(Map.keys(attrs), &(&1 in @fields)) do
        __MODULE__ |> struct(attrs) |> validate()
      else
        {:error, Error.new(:invalid_compaction_state, "compaction state has unknown fields")}
      end
    end
  end

  def new(_attrs), do: {:error, Error.new(:invalid_compaction_state, "compaction state must be a map")}

  defp normalize_keys(attrs) do
    Enum.reduce_while(attrs, {:ok, %{}}, fn {key, value}, {:ok, normalized} ->
      field = if is_binary(key), do: Map.get(@field_names, key, key), else: key

      if Map.has_key?(normalized, field) do
        {:halt, {:error, Error.new(:invalid_compaction_state, "compaction state has duplicate fields")}}
      else
        {:cont, {:ok, Map.put(normalized, field, value)}}
      end
    end)
  end

  @spec auto_suppression(t(), Policy.t()) :: nil | atom()
  def auto_suppression(%__MODULE__{} = state, %Policy{} = policy) do
    cond do
      state.cancellation_pending ->
        :cancellation_pending

      state.successful_auto_compactions >= policy.maximum_auto_compactions_per_root_turn ->
        :automatic_limit

      state.last_compaction_lane_event_ordinal != nil and
          state.new_tokens_since_compaction < policy.minimum_new_tokens_before_recompact ->
        :insufficient_new_tokens

      state.consecutive_ineffective_compactions > 0 and state.new_tokens_since_compaction == 0 ->
        :rapid_refill

      true ->
        nil
    end
  end

  @spec observe_new_tokens(t(), non_neg_integer()) :: {:ok, t()} | {:error, Error.t()}
  def observe_new_tokens(%__MODULE__{} = state, tokens)
      when is_integer(tokens) and tokens >= 0 do
    validate(%{state | new_tokens_since_compaction: tokens})
  end

  def observe_new_tokens(%__MODULE__{}, _tokens),
    do: {:error, Error.new(:invalid_compaction_state, "new-token count must be non-negative")}

  @spec record_success(t(), atom(), non_neg_integer(), non_neg_integer()) ::
          {:ok, t()} | {:error, Error.t()}
  def record_success(%__MODULE__{} = state, trigger, lane_ordinal, tokens_after)
      when trigger in [:auto, :manual, :overflow, :model_switch_preflight] and
             is_integer(lane_ordinal) and lane_ordinal >= 0 and is_integer(tokens_after) and
             tokens_after >= 0 do
    validate(%{
      state
      | successful_auto_compactions: state.successful_auto_compactions + if(trigger == :auto, do: 1, else: 0),
        last_compaction_lane_event_ordinal: lane_ordinal,
        last_compaction_tokens_after: tokens_after,
        new_tokens_since_compaction: 0,
        overflow_retry_used: state.overflow_retry_used or trigger == :overflow,
        consecutive_ineffective_compactions: 0
    })
  end

  def record_success(%__MODULE__{}, _trigger, _lane_ordinal, _tokens_after),
    do: {:error, Error.new(:invalid_compaction_state, "successful compaction evidence is invalid")}

  defp validate(state) do
    integers = [
      state.successful_auto_compactions,
      state.new_tokens_since_compaction,
      state.consecutive_ineffective_compactions
    ]

    nullable_integers = [
      state.last_compaction_lane_event_ordinal,
      state.last_compaction_tokens_after
    ]

    if Enum.all?(integers, &(is_integer(&1) and &1 >= 0)) and
         Enum.all?(nullable_integers, &(is_nil(&1) or (is_integer(&1) and &1 >= 0))) and
         is_boolean(state.overflow_retry_used) and is_boolean(state.cancellation_pending) do
      {:ok, state}
    else
      {:error, Error.new(:invalid_compaction_state, "compaction state is invalid")}
    end
  end
end
