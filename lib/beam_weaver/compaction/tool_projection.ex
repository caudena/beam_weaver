defmodule BeamWeaver.Compaction.ToolProjection do
  @moduledoc """
  Deterministic projection and recovery verification for large tool-result
  events used by application-owned compaction.

  Projection requires durable artifact identity before replacing large tool
  content with a bounded excerpt. `replay/2` verifies a persisted manifest
  against the original events before reproducing the projected lane.
  """

  import BeamWeaver.Compaction.Canonical, only: [hash?: 1]

  alias BeamWeaver.Compaction.{Canonical, InputEvent}
  alias BeamWeaver.Core.Error
  alias BeamWeaver.MapAccess
  alias BeamWeaver.Result

  @excerpt_bytes 1_024
  @projection_version 1

  @spec project([InputEvent.t()], MapSet.t()) ::
          {:ok, [InputEvent.t()], [map()]} | {:error, Error.t()}
  def project(events, protected_ids) do
    with {:ok, projections} <- Result.traverse(events, &project_event(&1, protected_ids)) do
      {projected, manifests} = Enum.unzip(projections)
      {:ok, projected, Enum.reject(manifests, &is_nil/1)}
    end
  end

  defp project_event(%InputEvent{role: :tool, content: content} = event, protected_ids)
       when is_binary(content) and byte_size(content) > @excerpt_bytes * 2 do
    if MapSet.member?(protected_ids, event.event_id) do
      {:ok, {event, nil}}
    else
      case event.artifact_ids do
        [] ->
          {:error,
           Error.new(
             :missing_compaction_artifact,
             "large tool output requires a durable artifact before projection",
             %{event_id: event.event_id}
           )}

        artifact_ids ->
          tool = Map.merge(event.tool || %{}, %{result_excerpt: excerpt(content), artifact_ids: artifact_ids})
          content_hash = Canonical.hash(%{content: nil, tool: tool, artifact_ids: artifact_ids, truncated: true})
          projected = %{event | content: nil, tool: tool, truncated: true, content_hash: content_hash, token_count: nil}

          manifest = %{
            projection_version: @projection_version,
            event_id: event.event_id,
            original_content_hash: event.content_hash,
            projected_content_hash: content_hash,
            original_bytes: byte_size(content),
            artifact_ids: artifact_ids
          }

          {:ok, {projected, manifest}}
      end
    end
  end

  defp project_event(event, _protected_ids), do: {:ok, {event, nil}}

  @doc "Replays and verifies an immutable tool-result projection manifest."
  @spec replay([InputEvent.t()], [map()]) :: {:ok, [InputEvent.t()]} | {:error, Error.t()}
  def replay(events, manifest) when is_list(events) and is_list(manifest) do
    with {:ok, entries} <- normalize_manifest(manifest) do
      by_id = Map.new(entries, &{&1.event_id, &1})
      event_ids = MapSet.new(events, & &1.event_id)

      if Enum.all?(entries, &MapSet.member?(event_ids, &1.event_id)) do
        Result.traverse(events, fn event ->
          case Map.get(by_id, event.event_id) do
            nil -> {:ok, event}
            entry -> replay_event(event, entry)
          end
        end)
      else
        projection_error("projection manifest references an unavailable event")
      end
    end
  end

  def replay(_events, _manifest), do: projection_error("projection replay input is invalid")

  defp replay_event(%InputEvent{role: :tool, content: content} = event, entry)
       when is_binary(content) do
    cond do
      byte_size(content) != entry.original_bytes ->
        projection_error("projection source byte length does not match", event.event_id)

      event.content_hash != entry.original_content_hash ->
        projection_error("projection source hash does not match", event.event_id)

      event.artifact_ids != entry.artifact_ids ->
        projection_error("projection artifact identity does not match", event.event_id)

      true ->
        with {:ok, {projected, manifest}} <- project_event(event, MapSet.new()),
             true <- manifest != nil,
             true <- projected.content_hash == entry.projected_content_hash do
          {:ok, projected}
        else
          false -> projection_error("projected event hash does not match", event.event_id)
          {:error, %Error{}} = error -> error
        end
    end
  end

  defp replay_event(event, _entry),
    do: projection_error("only complete tool results may be projected", event.event_id)

  defp normalize_manifest(entries) do
    entries =
      Enum.map(entries, fn entry ->
        %{
          projection_version: MapAccess.get(entry, :projection_version, 1),
          event_id: MapAccess.get(entry, :event_id),
          original_content_hash: MapAccess.get(entry, :original_content_hash),
          projected_content_hash: MapAccess.get(entry, :projected_content_hash),
          original_bytes: MapAccess.get(entry, :original_bytes),
          artifact_ids: MapAccess.get(entry, :artifact_ids, [])
        }
      end)

    valid? =
      Enum.all?(entries, fn entry ->
        entry.projection_version == @projection_version and is_binary(entry.event_id) and
          hash?(entry.original_content_hash) and hash?(entry.projected_content_hash) and
          is_integer(entry.original_bytes) and entry.original_bytes >= 0 and
          is_list(entry.artifact_ids) and Enum.all?(entry.artifact_ids, &is_binary/1)
      end)

    if valid? and length(Enum.uniq_by(entries, & &1.event_id)) == length(entries),
      do: {:ok, entries},
      else: projection_error("projection manifest is invalid")
  end

  defp projection_error(message, event_id \\ nil),
    do:
      {:error,
       Error.new(
         :invalid_compaction_projection,
         message,
         if(event_id, do: %{event_id: event_id}, else: %{})
       )}

  defp excerpt(content) do
    first = safe_prefix(content, @excerpt_bytes)
    last = content |> binary_part(byte_size(content) - @excerpt_bytes, @excerpt_bytes) |> safe_suffix()
    first <> "\n...[projected]...\n" <> last
  end

  defp safe_prefix(content, size) do
    prefix = binary_part(content, 0, min(size, byte_size(content)))
    if String.valid?(prefix), do: prefix, else: safe_prefix(content, size - 1)
  end

  defp safe_suffix(content) do
    if String.valid?(content),
      do: content,
      else: content |> binary_part(1, byte_size(content) - 1) |> safe_suffix()
  end
end
