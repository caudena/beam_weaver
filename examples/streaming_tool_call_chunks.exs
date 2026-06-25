alias BeamWeaver.Core.Messages
alias BeamWeaver.Stream
alias BeamWeaver.Stream.Envelope
alias BeamWeaver.Stream.Events
alias BeamWeaver.Stream.Finalize

events = [
  %Envelope{
    event: %Events.MessageChunk{
      chunk:
        Messages.ai_chunk("",
          id: "msg-1",
          tool_call_chunks: [
            Messages.tool_call_chunk(
              id: "call_weather",
              index: 0,
              name: "get_weather",
              args: ~s({"city")
            )
          ]
        )
    },
    run_id: "run-1",
    node: "llm"
  },
  %Envelope{
    event: %Events.MessageChunk{
      chunk:
        Messages.ai_chunk("",
          id: "msg-1",
          tool_call_chunks: [
            Messages.tool_call_chunk(
              id: "call_weather",
              index: 0,
              args: ~s(: "Nicosia"})
            )
          ]
        )
    },
    run_id: "run-1",
    node: "llm"
  }
]

for %Envelope{event: %Events.MessageChunk{chunk: chunk}} <- events,
    tool_chunk <- chunk.tool_call_chunks do
  IO.inspect(
    %{id: tool_chunk.id, name: tool_chunk.name, args_delta: tool_chunk.args},
    label: "streamed tool-call chunk"
  )
end

final_message =
  events
  |> Enum.map(fn %Envelope{event: %Events.MessageChunk{chunk: chunk}} -> chunk end)
  |> Finalize.finalize()

IO.inspect(final_message.tool_calls, label: "reconstructed tool calls")
IO.inspect(Stream.event_mode(hd(events).event), label: "native stream mode")
