# Streaming: print the answer word by word as the model writes it, and see
# each tool call as it starts. `stream: true` asks the provider for tokens;
# `live: true` hands over events while the agent runs.
#
#   mix run examples/streaming_agent.exs

Code.require_file("support.exs", __DIR__)

alias BeamWeaver.Core.Message
alias BeamWeaver.Examples.Support
alias BeamWeaver.Stream.Envelope
alias BeamWeaver.Stream.Events

defmodule BeamWeaver.Examples.StreamingAgent.GetWeather do
  use BeamWeaver.Tool

  name "get_weather"
  description "Get the current weather for a city."

  schema do
    field :city, :string, description: "The city name"
  end

  @impl true
  def invoke(_tool, %{"city" => city}, _opts), do: {:ok, "Light rain and 14°C in #{city}."}
end

defmodule BeamWeaver.Examples.StreamingAgent do
  use BeamWeaver.Agent

  model Support.model(), stream: true
  system_prompt "Use get_weather for questions about the weather."
  tools [BeamWeaver.Examples.StreamingAgent.GetWeather]
end

{:ok, events} =
  BeamWeaver.Examples.StreamingAgent.stream_events(
    %{messages: ["Should I take an umbrella in Lisbon today? Answer in two sentences."]},
    live: true
  )

# A Token event is a piece of text; a Message event carries a finished message.
%{messages: messages, tokens: tokens} =
  Enum.reduce(events, %{messages: [], tokens: 0}, fn %Envelope{event: event}, acc ->
    case event do
      %Events.Token{text: text} ->
        IO.write(text)
        %{acc | tokens: acc.tokens + 1}

      %Events.ToolStart{tool_name: name, input: input} ->
        IO.puts("[calling #{name} with #{inspect(input)}]")
        acc

      %Events.Message{message: %Message{} = message} ->
        %{acc | messages: acc.messages ++ [message]}

      %Events.ToolFinish{tool_call_id: id, output: output} ->
        %{acc | messages: acc.messages ++ [Message.tool(output, tool_call_id: id)]}

      %Events.Error{error: error} ->
        raise "the stream failed: #{error.message}"

      _other ->
        acc
    end
  end)

IO.puts("")
true = tokens > 0
Support.assert_text!(List.last(messages))

Support.assert_tools_called!(messages, [
  {"get_weather", fn args -> String.contains?(String.downcase(args["city"] || ""), "lisbon") end}
])
