defmodule BeamWeaver.Compaction.State do
  @moduledoc """
  Bounded lane-local circuit state for automatic compaction.

  Applications persist one state with each active conversation-lane head. The
  engine reads it to suppress unsafe or wasteful automatic attempts, and
  returns it in `BeamWeaver.Compaction.Result`, rebased to the request's
  accounting and root turn. Advance it with `record_success/2` only after the
  corresponding checkpoint has been durably activated.

  The automatic-compaction count and the overflow retry belong to one root
  turn (`root_turn_id`): a new root turn starts with neither used.
  """

  import BeamWeaver.Compaction.Canonical, only: [hash?: 1]

  alias BeamWeaver.Compaction.{Checkpoint, Fields, Policy}
  alias BeamWeaver.Core.Error
  alias BeamWeaver.MapAccess

  @fields [
    :root_turn_id,
    :successful_auto_compactions,
    :last_compaction_lane_event_ordinal,
    :last_compaction_tokens_after,
    :new_tokens_since_compaction,
    :overflow_retry_used,
    :consecutive_ineffective_compactions,
    :cancellation_pending,
    :accounting_method,
    :accounting_version,
    :accounting_profile_hash
  ]
  @field_names Map.new(@fields, &{Atom.to_string(&1), &1})

  defstruct root_turn_id: nil,
            successful_auto_compactions: 0,
            last_compaction_lane_event_ordinal: nil,
            last_compaction_tokens_after: nil,
            new_tokens_since_compaction: 0,
            overflow_retry_used: false,
            consecutive_ineffective_compactions: 0,
            cancellation_pending: false,
            accounting_method: nil,
            accounting_version: nil,
            accounting_profile_hash: nil

  @type t :: %__MODULE__{}

  @doc "Builds and validates persisted lane-local compaction state."
  @spec new(map() | t()) :: {:ok, t()} | {:error, Error.t()}
  def new(%__MODULE__{} = state), do: validate(state)

  def new(%{} = attrs) do
    with {:ok, attrs} <- Fields.normalize(attrs, @field_names),
         {:ok, attrs} <- normalize_accounting_method(attrs) do
      if Enum.all?(Map.keys(attrs), &(&1 in @fields)) do
        __MODULE__ |> struct(attrs) |> validate()
      else
        {:error, Error.new(:invalid_compaction_state, "compaction state has unknown fields")}
      end
    else
      {:error, :duplicate_field} ->
        {:error, Error.new(:invalid_compaction_state, "compaction state has duplicate fields")}

      {:error, %Error{}} = error ->
        error
    end
  end

  def new(_attrs), do: {:error, Error.new(:invalid_compaction_state, "compaction state must be a map")}

  @doc """
  Returns the current automatic-compaction suppression reason, or `nil`.

  Reasons are `:cancellation_pending`, `:automatic_limit`,
  `:insufficient_new_tokens`, and `:rapid_refill`. The automatic limit counts
  the compactions of the state's root turn; call `for_root_turn/2` first when
  a new root turn may have started.
  """
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

  @doc "Sets the observed amount of new context since the active checkpoint."
  @spec observe_new_tokens(t(), non_neg_integer()) :: {:ok, t()} | {:error, Error.t()}
  def observe_new_tokens(%__MODULE__{} = state, tokens)
      when is_integer(tokens) and tokens >= 0 do
    validate(%{state | new_tokens_since_compaction: tokens})
  end

  def observe_new_tokens(%__MODULE__{}, _tokens),
    do: {:error, Error.new(:invalid_compaction_state, "new-token count must be non-negative")}

  @doc """
  Returns the state for `root_turn_id`.

  When it names a new root turn, the automatic-compaction count starts again
  at zero and the overflow retry is unused again.
  """
  @spec for_root_turn(t(), String.t()) :: {:ok, t()} | {:error, Error.t()}
  def for_root_turn(%__MODULE__{root_turn_id: root_turn_id} = state, root_turn_id), do: validate(state)

  def for_root_turn(%__MODULE__{} = state, root_turn_id) do
    validate(%{state | root_turn_id: root_turn_id, successful_auto_compactions: 0, overflow_retry_used: false})
  end

  @doc "Rebases only unit-dependent anti-thrash fields when accounting identity changes."
  @spec rebase_accounting(t(), map()) :: {:ok, t()} | {:error, Error.t()}
  def rebase_accounting(%__MODULE__{} = state, identity) when is_map(identity) do
    method = identity |> MapAccess.get(:method) |> normalize_accounting_identity_method()
    version = MapAccess.get(identity, :version)
    profile_hash = MapAccess.get(identity, :profile_hash)

    if valid_accounting?(method, version, profile_hash) do
      same? =
        state.accounting_method == method and state.accounting_version == version and
          state.accounting_profile_hash == profile_hash

      next =
        if same? do
          state
        else
          %{
            state
            | last_compaction_lane_event_ordinal: nil,
              last_compaction_tokens_after: nil,
              new_tokens_since_compaction: 0,
              consecutive_ineffective_compactions: 0,
              accounting_method: method,
              accounting_version: version,
              accounting_profile_hash: profile_hash
          }
        end

      validate(next)
    else
      {:error, Error.new(:invalid_compaction_state, "accounting identity is invalid")}
    end
  end

  def rebase_accounting(%__MODULE__{}, _identity),
    do: {:error, Error.new(:invalid_compaction_state, "accounting identity is invalid")}

  @doc """
  Records the activation of a checkpoint from a manual, automatic, overflow,
  or model-switch compaction.

  The state takes the checkpoint's accounting identity and root turn, so call
  it on the state the checkpoint was built from, such as the result's
  `anti_thrash`.
  """
  @spec record_success(t(), Checkpoint.t()) :: {:ok, t()} | {:error, Error.t()}
  def record_success(%__MODULE__{} = state, %Checkpoint{trigger: trigger} = checkpoint)
      when trigger in [:auto, :manual, :overflow, :model_switch_preflight] do
    identity = %{
      method: checkpoint.accounting_method,
      version: checkpoint.accounting_version,
      profile_hash: checkpoint.accounting_profile_hash
    }

    with {:ok, state} <- rebase_accounting(state, identity),
         {:ok, state} <- for_root_turn(state, checkpoint.root_turn_id) do
      validate(%{
        state
        | successful_auto_compactions: state.successful_auto_compactions + if(trigger == :auto, do: 1, else: 0),
          last_compaction_lane_event_ordinal: checkpoint.context_lane_event_ordinal_high_watermark,
          last_compaction_tokens_after: checkpoint.tokens_after,
          new_tokens_since_compaction: 0,
          overflow_retry_used: state.overflow_retry_used or trigger == :overflow,
          consecutive_ineffective_compactions: 0
      })
    end
  end

  def record_success(%__MODULE__{}, _checkpoint),
    do: {:error, Error.new(:invalid_compaction_state, "successful compaction evidence is invalid")}

  @doc """
  Records a compaction attempt that didn't reclaim enough context.

  Automatic compaction then pauses (`:rapid_refill`) until
  `observe_new_tokens/2` reports new context. The engine records its own
  ineffective attempts: the `:ineffective_compaction` error carries the
  updated state in `details.anti_thrash`.
  """
  @spec record_ineffective(t()) :: {:ok, t()} | {:error, Error.t()}
  def record_ineffective(%__MODULE__{} = state) do
    validate(%{
      state
      | consecutive_ineffective_compactions: state.consecutive_ineffective_compactions + 1,
        new_tokens_since_compaction: 0
    })
  end

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
         (is_nil(state.root_turn_id) or (is_binary(state.root_turn_id) and byte_size(state.root_turn_id) in 1..200)) and
         is_boolean(state.overflow_retry_used) and is_boolean(state.cancellation_pending) and
         valid_optional_accounting?(state.accounting_method, state.accounting_version, state.accounting_profile_hash) do
      {:ok, state}
    else
      {:error, Error.new(:invalid_compaction_state, "compaction state is invalid")}
    end
  end

  defp valid_optional_accounting?(nil, nil, nil), do: true
  defp valid_optional_accounting?(method, version, profile_hash), do: valid_accounting?(method, version, profile_hash)

  defp valid_accounting?(method, version, profile_hash),
    do:
      method in [:conservative_utf8, :local_tokenizer_v1, :reported_usage_delta_v2] and
        is_integer(version) and
        version > 0 and (is_nil(profile_hash) or hash?(profile_hash))

  defp normalize_accounting_method(%{accounting_method: method} = attrs)
       when method in ["conservative_utf8", "local_tokenizer_v1", "reported_usage_delta_v2"] do
    {:ok, %{attrs | accounting_method: String.to_existing_atom(method)}}
  end

  defp normalize_accounting_method(%{accounting_method: method}) when is_binary(method),
    do: {:error, Error.new(:invalid_compaction_state, "compaction accounting method is invalid")}

  defp normalize_accounting_method(attrs), do: {:ok, attrs}

  defp normalize_accounting_identity_method(method)
       when method in ["conservative_utf8", "local_tokenizer_v1", "reported_usage_delta_v2"],
       do: String.to_existing_atom(method)

  defp normalize_accounting_identity_method(method), do: method
end
