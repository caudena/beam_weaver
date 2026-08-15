defmodule BeamWeaver.Compaction.InputEvent do
  @moduledoc """
  Closed lane-local source event consumed by the compactor.

  Events retain role, provenance, content/tool projection, artifact references,
  ordering, and protection state. `provenance_sha256` must hash `provenance`;
  `content_hash` must hash exactly `content`, `tool`, `artifact_ids`, and
  `truncated` with `BeamWeaver.Compaction.Canonical.hash/1`.
  """

  alias BeamWeaver.Compaction.{Canonical, Fields}
  alias BeamWeaver.Core.Error

  @fields [
    :event_id,
    :chat_seq,
    :run_agent_id,
    :checkpoint_namespace,
    :lane_event_ordinal,
    :role,
    :provenance,
    :provenance_sha256,
    :content,
    :tool,
    :artifact_ids,
    :truncated,
    :content_hash,
    :token_count,
    :protected
  ]
  @field_names Map.new(@fields, &{Atom.to_string(&1), &1})

  @enforce_keys [
    :event_id,
    :chat_seq,
    :run_agent_id,
    :checkpoint_namespace,
    :lane_event_ordinal,
    :role,
    :provenance,
    :provenance_sha256,
    :content_hash
  ]
  defstruct @enforce_keys ++
              [
                content: nil,
                tool: nil,
                artifact_ids: [],
                truncated: false,
                token_count: nil,
                protected: false
              ]

  @type t :: %__MODULE__{}

  @doc "Builds and validates a closed compaction source event."
  @spec new(map() | t()) :: {:ok, t()} | {:error, Error.t()}
  def new(%__MODULE__{} = event), do: validate(event)

  def new(%{} = attrs) do
    with {:ok, attrs} <- Fields.normalize(attrs, @field_names) do
      unknown = Map.keys(attrs) -- @fields

      if unknown == [] do
        {:ok, struct!(__MODULE__, attrs)}
        |> then(fn {:ok, event} -> validate(event) end)
      else
        {:error, Error.new(:invalid_compaction_event, "unknown event fields", %{fields: unknown})}
      end
    else
      {:error, :duplicate_field} -> invalid("event has duplicate fields")
    end
  rescue
    _error -> {:error, Error.new(:invalid_compaction_event, "required event fields are missing")}
  end

  def new(_attrs), do: {:error, Error.new(:invalid_compaction_event, "event must be a map")}

  @doc "Returns the explicit event token count or a conservative canonical byte count."
  @spec estimated_tokens(t()) :: non_neg_integer()
  def estimated_tokens(%__MODULE__{token_count: count}) when is_integer(count) and count >= 0, do: count

  def estimated_tokens(%__MODULE__{} = event) do
    event
    |> to_map()
    |> BeamWeaver.JSON.encode!()
    |> byte_size()
  end

  @doc "Converts an event to the canonical summary-callback source shape."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = event) do
    event
    |> Map.from_struct()
    |> Map.update!(:role, &Atom.to_string/1)
    |> Map.delete(:token_count)
    |> Map.delete(:protected)
  end

  defp validate(%__MODULE__{} = event) do
    cond do
      not id?(event.event_id) or not id?(event.run_agent_id) -> invalid("event identities are invalid")
      not (is_integer(event.chat_seq) and event.chat_seq > 0) -> invalid("chat sequence is invalid")
      not (is_integer(event.lane_event_ordinal) and event.lane_event_ordinal > 0) -> invalid("lane ordinal is invalid")
      not namespace?(event.checkpoint_namespace) -> invalid("checkpoint namespace is invalid")
      event.role not in [:user, :assistant, :tool] -> invalid("event role is invalid")
      not Canonical.json_value?(event.provenance) -> invalid("provenance is not canonical data")
      not hash?(event.provenance_sha256) or not hash?(event.content_hash) -> invalid("event hashes are invalid")
      Canonical.hash(event.provenance) != event.provenance_sha256 -> invalid("provenance hash does not match")
      not content?(event.content) -> invalid("event content is invalid")
      not tool?(event.tool) -> invalid("event tool projection is invalid")
      not ids?(event.artifact_ids) -> invalid("event artifact IDs are invalid")
      Canonical.hash(payload(event)) != event.content_hash -> invalid("content hash does not match")
      not is_boolean(event.truncated) or not is_boolean(event.protected) -> invalid("event flags are invalid")
      not token_count?(event.token_count) -> invalid("event token count is invalid")
      true -> {:ok, event}
    end
  end

  defp invalid(message), do: {:error, Error.new(:invalid_compaction_event, message)}
  defp id?(value), do: is_binary(value) and byte_size(value) in 1..200
  defp hash?(value), do: is_binary(value) and byte_size(value) == 64 and value =~ ~r/\A[0-9a-f]{64}\z/
  defp namespace?(value), do: is_binary(value) and byte_size(value) in 1..200 and String.valid?(value)
  defp content?(nil), do: true
  defp content?(value), do: is_binary(value) and byte_size(value) <= 1_048_576 and String.valid?(value)
  defp tool?(nil), do: true
  defp tool?(value), do: is_map(value) and Canonical.json_value?(value)
  defp ids?(values), do: is_list(values) and length(values) <= 128 and Enum.all?(values, &id?/1)
  defp token_count?(nil), do: true
  defp token_count?(value), do: is_integer(value) and value >= 0

  defp payload(event) do
    %{
      content: event.content,
      tool: event.tool,
      artifact_ids: event.artifact_ids,
      truncated: event.truncated
    }
  end
end
