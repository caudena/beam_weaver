defmodule BeamWeaver.Compaction.Request do
  @moduledoc """
  Validated input and application callbacks for one compaction attempt.

  A request binds one ordered conversation lane to an exact provider
  connection, destination identity, model profile, active checkpoint parent,
  policy, and rehydration state. `render/2` must return the exact provider
  request bytes for a semantic checkpoint and retained event list.
  `summarize/1` is the sole model boundary and returns `{:ok, semantic}` or
  `{:ok, semantic, usage}`.

  The application remains responsible for idempotency, provider admission,
  timeout/cancellation enforcement, persistence, active-head fencing, and
  recovery. In particular, `deadline_at` and `Policy.provider_timeout_ms` are
  carried as policy data; this pure value cannot enforce a callback's runtime.
  """

  alias BeamWeaver.Compaction.{InputEvent, Policy, RehydrationState, Semantic, State}
  alias BeamWeaver.Core.Error

  @enforce_keys [
    :request_id,
    :trigger,
    :thread_id,
    :run_id,
    :root_turn_id,
    :run_agent_id,
    :checkpoint_namespace,
    :provider_connection_id,
    :destination_identity_hash,
    :model_profile,
    :rendered_request,
    :events,
    :rehydration_state,
    :policy,
    :render,
    :summarize
  ]
  defstruct @enforce_keys ++
              [
                :parent_checkpoint_id,
                :previous_semantic,
                :focus,
                :deadline_at,
                active_input_event_ids: [],
                requested_max_output_tokens: 0,
                anti_thrash: %State{}
              ]

  @type render_fun :: (Semantic.t() | nil, [InputEvent.t()] -> {:ok, binary()} | {:error, term()})
  @type summarize_fun :: (map() -> {:ok, map()} | {:ok, map(), map()} | {:error, term()})
  @type t :: %__MODULE__{}

  @doc "Builds and validates one closed compaction request."
  @spec new(map() | t()) :: {:ok, t()} | {:error, Error.t()}
  def new(%__MODULE__{} = request), do: validate(request)

  def new(%{} = attrs) do
    {:ok, struct!(__MODULE__, attrs)}
    |> then(fn {:ok, request} -> validate(request) end)
  rescue
    _error -> {:error, Error.new(:invalid_compaction_request, "required compaction request fields are missing")}
  end

  def new(_attrs), do: {:error, Error.new(:invalid_compaction_request, "compaction request must be a map")}

  @doc "Returns the inclusive first and last source chat sequence."
  @spec source_range(t()) :: {pos_integer(), pos_integer()}
  def source_range(%__MODULE__{events: events}) do
    {List.first(events).chat_seq, List.last(events).chat_seq}
  end

  defp validate(%__MODULE__{} = request) do
    with :ok <- ids(request),
         :ok <- trigger(request),
         :ok <- hashes(request),
         {:ok, policy} <- Policy.new(request.policy),
         true <- policy.mode in [:portable, :native],
         true <- request.trigger != :auto or policy.enabled,
         true <- request.trigger != :manual or byte_size(request.focus || "") <= 2_000,
         {:ok, rehydration} <- RehydrationState.new(request.rehydration_state),
         {:ok, previous} <- previous_semantic(request.previous_semantic),
         {:ok, anti_thrash} <- State.new(request.anti_thrash),
         {:ok, events} <- events(request.events, request),
         :ok <- active_ids(request.active_input_event_ids, events),
         true <- is_binary(request.rendered_request),
         true <- is_function(request.render, 2),
         true <- is_function(request.summarize, 1),
         true <- non_negative_integer?(request.requested_max_output_tokens) do
      {:ok,
       %{
         request
         | policy: policy,
           rehydration_state: rehydration,
           previous_semantic: previous,
           anti_thrash: anti_thrash,
           events: events
       }}
    else
      false -> invalid("compaction request is invalid")
      {:error, %Error{}} = error -> error
      {:error, reason} -> invalid("compaction request is invalid", %{reason: inspect(reason)})
    end
  end

  defp ids(request) do
    values = [
      request.request_id,
      request.thread_id,
      request.run_id,
      request.root_turn_id,
      request.run_agent_id,
      request.provider_connection_id
    ]

    if Enum.all?(values, &id?/1) and nullable_id?(request.parent_checkpoint_id),
      do: :ok,
      else: invalid("compaction request identities are invalid")
  end

  defp trigger(request) do
    if request.trigger in [:auto, :manual, :overflow, :model_switch_preflight],
      do: :ok,
      else: invalid("compaction trigger is invalid")
  end

  defp hashes(request) do
    if hash?(request.destination_identity_hash),
      do: :ok,
      else: invalid("destination identity hash is invalid")
  end

  defp events(values, request) when is_list(values) and values != [] and length(values) <= 10_000 do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case InputEvent.new(value) do
        {:ok, event} -> {:cont, {:ok, [event | acc]}}
        {:error, %Error{}} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, reversed} ->
        events = Enum.reverse(reversed)

        if ordered_lane?(events, request),
          do: {:ok, events},
          else: invalid("compaction events are not one ordered lane")

      error ->
        error
    end
  end

  defp events(_values, _request), do: invalid("compaction event sequence is empty or oversized")

  defp ordered_lane?(events, request) do
    {ordinals, unique_ids} =
      Enum.reduce(events, {[], MapSet.new()}, fn event, {ordinals, ids} ->
        {[event.lane_event_ordinal | ordinals], MapSet.put(ids, event.event_id)}
      end)

    ordinals = Enum.reverse(ordinals)

    Enum.all?(events, fn event ->
      event.run_agent_id == request.run_agent_id and
        event.checkpoint_namespace == request.checkpoint_namespace
    end) and ordinals == Enum.sort(ordinals) and MapSet.size(unique_ids) == length(events)
  end

  defp active_ids(ids, events) when is_list(ids) do
    available = MapSet.new(events, & &1.event_id)

    if length(ids) == length(Enum.uniq(ids)) and Enum.all?(ids, &MapSet.member?(available, &1)),
      do: :ok,
      else: invalid("active input event IDs are invalid")
  end

  defp active_ids(_ids, _events), do: invalid("active input event IDs are invalid")
  defp previous_semantic(nil), do: {:ok, nil}
  defp previous_semantic(value), do: Semantic.new(value)
  defp id?(value), do: is_binary(value) and byte_size(value) in 1..200
  defp nullable_id?(nil), do: true
  defp nullable_id?(value), do: id?(value)
  defp hash?(value), do: is_binary(value) and value =~ ~r/\A[0-9a-f]{64}\z/
  defp non_negative_integer?(value), do: is_integer(value) and value >= 0
  defp invalid(message, details \\ %{}), do: {:error, Error.new(:invalid_compaction_request, message, details)}
end
