defimpl BeamWeaver.Stream.IntoEvent,
  for: [
    BeamWeaver.Stream.Events.Token,
    BeamWeaver.Stream.Events.MessageChunk,
    BeamWeaver.Stream.Events.Message,
    BeamWeaver.Stream.Events.ToolCallChunk,
    BeamWeaver.Stream.Events.ToolStart,
    BeamWeaver.Stream.Events.ToolDelta,
    BeamWeaver.Stream.Events.ToolFinish,
    BeamWeaver.Stream.Events.ToolError,
    BeamWeaver.Stream.Events.GraphUpdate,
    BeamWeaver.Stream.Events.GraphValue,
    BeamWeaver.Stream.Events.Checkpoint,
    BeamWeaver.Stream.Events.Task,
    BeamWeaver.Stream.Events.Lifecycle,
    BeamWeaver.Stream.Events.Debug,
    BeamWeaver.Stream.Events.Custom,
    BeamWeaver.Stream.Events.Error,
    BeamWeaver.Stream.Events.Done
  ] do
  def into_event(event), do: event
end

defimpl BeamWeaver.Stream.IntoEvent, for: BeamWeaver.Core.Messages.AIChunk do
  def into_event(chunk), do: %BeamWeaver.Stream.Events.MessageChunk{chunk: chunk}
end

defimpl BeamWeaver.Stream.IntoEvent, for: BeamWeaver.Core.Messages.ToolCallChunk do
  def into_event(chunk), do: %BeamWeaver.Stream.Events.ToolCallChunk{chunk: chunk}
end

defimpl BeamWeaver.Stream.IntoEvent, for: BeamWeaver.Core.Message do
  def into_event(message), do: %BeamWeaver.Stream.Events.Message{message: message}
end

defimpl BeamWeaver.Stream.Finalize, for: BeamWeaver.Core.Messages.AIChunk do
  alias BeamWeaver.Core.Messages.MessageChunk

  def finalize(chunk), do: MessageChunk.to_message(chunk)
end

defimpl BeamWeaver.Stream.Finalize, for: List do
  alias BeamWeaver.Core.Messages.AIChunk
  alias BeamWeaver.Core.Messages.MessageChunk

  def finalize([%AIChunk{} | _rest] = chunks) do
    chunks
    |> MessageChunk.merge_many()
    |> MessageChunk.to_message()
  end

  def finalize(value), do: value
end
