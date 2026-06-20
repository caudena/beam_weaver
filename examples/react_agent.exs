Code.require_file("support.exs", __DIR__)

alias BeamWeaver.Core.Message
alias BeamWeaver.Core.Tool
alias BeamWeaver.Examples.Support

defmodule BeamWeaver.Examples.ReactAgent do
  use BeamWeaver.Agent

  name("react_agent")
  description("Answer questions, calling tools when useful.")
  model(Support.model())
  system_prompt("You are a helpful assistant. Use the weather tool when asked about the weather.")

  tools do
    tool(
      Tool.from_function!(
        name: "weather",
        description: "Get the current weather for a city.",
        input_schema: %{
          "type" => "object",
          "properties" => %{"city" => %{"type" => "string"}},
          "required" => ["city"]
        },
        handler: fn %{"city" => city}, _opts -> "Sunny, 25°C in #{city}." end
      )
    )
  end
end

{:ok, %{messages: messages}} =
  BeamWeaver.Examples.ReactAgent.invoke(%{messages: [Message.user("What is the weather in Nicosia?")]})

messages |> List.last() |> Message.text() |> IO.puts()
