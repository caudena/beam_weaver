defmodule BeamWeaver.Compaction.ToolProjection do
  @moduledoc false

  alias BeamWeaver.Compaction.{Canonical, InputEvent}
  alias BeamWeaver.Core.Error

  @excerpt_bytes 1_024

  @spec project([InputEvent.t()], MapSet.t()) ::
          {:ok, [InputEvent.t()], [map()]} | {:error, Error.t()}
  def project(events, protected_ids) do
    Enum.reduce_while(events, {:ok, [], []}, fn event, {:ok, acc, manifests} ->
      case project_event(event, protected_ids) do
        {:ok, projected, nil} -> {:cont, {:ok, [projected | acc], manifests}}
        {:ok, projected, manifest} -> {:cont, {:ok, [projected | acc], [manifest | manifests]}}
        {:error, %Error{}} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, events, manifests} -> {:ok, Enum.reverse(events), Enum.reverse(manifests)}
      error -> error
    end
  end

  defp project_event(%InputEvent{role: :tool, content: content} = event, protected_ids)
       when is_binary(content) and byte_size(content) > @excerpt_bytes * 2 do
    if MapSet.member?(protected_ids, event.event_id) do
      {:ok, event, nil}
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
          excerpt = excerpt(content)
          tool = Map.merge(event.tool || %{}, %{result_excerpt: excerpt, artifact_ids: artifact_ids})
          content = nil

          payload = %{
            content: content,
            tool: tool,
            artifact_ids: artifact_ids,
            truncated: true
          }

          projected = %{
            event
            | content: content,
              tool: tool,
              truncated: true,
              content_hash: Canonical.hash(payload),
              token_count: nil
          }

          manifest = %{
            event_id: event.event_id,
            original_content_hash: event.content_hash,
            projected_content_hash: projected.content_hash,
            original_bytes: byte_size(event.content),
            artifact_ids: artifact_ids
          }

          {:ok, projected, manifest}
      end
    end
  end

  defp project_event(event, _protected_ids), do: {:ok, event, nil}

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
