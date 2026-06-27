alias BeamWeaver.Agent.Middleware.PII
alias BeamWeaver.Core.Messages
alias BeamWeaver.Stream.Envelope
alias BeamWeaver.Stream.Events
alias BeamWeaver.Stream.MessageStream
alias BeamWeaver.Stream.MessagesTransformer

transformer =
  MessagesTransformer.new(pre_projection: PII.stream_transform(type: :email, strategy: :redact))

events = [
  %{
    "type" => "event",
    "method" => "messages",
    "params" => %{
      "data" =>
        {%{"event" => "message-start", "role" => "ai", "message_id" => "msg-1"},
         %{"node" => "llm", "run_id" => "run-1"}}
    }
  },
  %Envelope{
    event: %Events.MessageChunk{chunk: Messages.ai_chunk("email ada@example.com")},
    node: "llm",
    run_id: "run-1"
  },
  %{
    "type" => "event",
    "method" => "messages",
    "params" => %{
      "data" => {%{"event" => "message-finish", "reason" => "stop"}, %{"node" => "llm", "run_id" => "run-1"}}
    }
  }
]

{:ok, transformer, _emitted} = MessagesTransformer.process_many(transformer, events)

for stream <- MessagesTransformer.streams(transformer) do
  IO.puts(MessageStream.text(stream))
end
