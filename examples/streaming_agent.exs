alias BeamWeaver.Core.ChatModel
alias BeamWeaver.Core.Message
alias BeamWeaver.Stream.Envelope

defmodule BeamWeaver.Examples.StreamingAgent.Model do
  @behaviour ChatModel

  defstruct []

  def invoke(%__MODULE__{}, _messages, _opts), do: {:ok, Message.assistant("streamed")}
end

defmodule BeamWeaver.Examples.StreamingAgent do
  use BeamWeaver.Agent

  model(%BeamWeaver.Examples.StreamingAgent.Model{})
end

{:ok, events} =
  BeamWeaver.Examples.StreamingAgent.stream_events(%{messages: [Message.user("hello")]})

events
|> Enum.filter(&match?(%Envelope{}, &1))
|> length()
|> IO.puts()
