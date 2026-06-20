Code.require_file("support.exs", __DIR__)

alias BeamWeaver.Core.Message
alias BeamWeaver.Examples.Support
alias BeamWeaver.Stream.Envelope

defmodule BeamWeaver.Examples.StreamingAgent do
  use BeamWeaver.Agent

  name("streaming_agent")
  model(Support.model())
end

{:ok, events} =
  BeamWeaver.Examples.StreamingAgent.stream_events(%{
    messages: [Message.user("Say hello in one short sentence.")]
  })

events
|> Enum.filter(&match?(%Envelope{}, &1))
|> length()
|> IO.puts()
