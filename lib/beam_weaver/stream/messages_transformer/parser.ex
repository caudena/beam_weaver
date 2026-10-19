defmodule BeamWeaver.Stream.MessagesTransformer.Parser do
  @moduledoc false

  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Messages.AIChunk
  alias BeamWeaver.Core.Messages.Chunk
  alias BeamWeaver.Core.Messages.MessageChunk
  alias BeamWeaver.MapAccess
  alias BeamWeaver.Stream.Events

  def parse(%BeamWeaver.Stream.Envelope{
        event: %Events.Message{message: message, metadata: metadata}
      })
      when is_map(metadata),
      do: {:whole_message, message, metadata}

  def parse(%BeamWeaver.Stream.Envelope{
        event: %Events.MessageChunk{chunk: chunk},
        node: node,
        run_id: run_id
      }) do
    metadata = %{node: node, run_id: run_id}
    {:protocol, chunk_to_delta(chunk), metadata}
  end

  def parse(%{"type" => "event", "method" => method, "params" => params})
      when method in ["messages", :messages],
      do: parse_message_params(params)

  def parse(%{type: "event", method: method, params: params})
      when method in ["messages", :messages],
      do: parse_message_params(params)

  def parse(%{type: :event, method: method, params: params})
      when method in ["messages", :messages],
      do: parse_message_params(params)

  def parse(%{"type" => "event"}), do: :pass
  def parse(%{type: "event"}), do: :pass
  def parse(%{type: :event}), do: :pass
  def parse(_event), do: :ignore

  defp parse_message_params(params) when is_map(params) do
    if List.wrap(MapAccess.get(params, :namespace)) == [] do
      case MapAccess.get(params, :data) do
        {%Message{} = message, metadata} ->
          {:whole_message, message, normalize_metadata(metadata)}

        {%AIChunk{}, _metadata} ->
          :ignore

        {%Chunk{}, _metadata} ->
          :ignore

        {%{} = payload, metadata} ->
          {:protocol, payload, normalize_metadata(metadata)}

        _other ->
          :ignore
      end
    else
      :ignore
    end
  end

  defp parse_message_params(_params), do: :ignore

  defp chunk_to_delta(chunk),
    do: %{event: "content-block-delta", index: 0, content_block: %{type: "text", text: chunk_text(chunk)}}

  defp chunk_text(%AIChunk{content: content}), do: content || ""
  defp chunk_text(chunk), do: MessageChunk.to_message(chunk).content

  defp normalize_metadata(metadata) when is_map(metadata), do: metadata
  defp normalize_metadata(_metadata), do: %{}
end
