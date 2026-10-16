# A tool-calling agent: the model calls get_weather, reads the result, and
# answers.
#
#   export OPENAI_API_KEY=...
#   mix run examples/react_agent.exs
#
# Another provider: BEAM_WEAVER_EXAMPLES_MODEL=anthropic:claude-haiku-4-5 with ANTHROPIC_API_KEY.

Code.require_file("support.exs", __DIR__)

alias BeamWeaver.Core.Message
alias BeamWeaver.Examples.Support

defmodule BeamWeaver.Examples.ReactAgent.GetWeather do
  use BeamWeaver.Tool

  name "get_weather"
  description "Get the current weather for a city."

  schema do
    field :city, :string, description: "The city name"
  end

  @impl true
  def invoke(_tool, %{"city" => city}, _opts), do: {:ok, "Sunny and 25°C in #{city}."}
end

defmodule BeamWeaver.Examples.ReactAgent do
  use BeamWeaver.Agent

  model Support.model()
  system_prompt "You are a helpful assistant. Use get_weather for questions about the weather."
  tools [BeamWeaver.Examples.ReactAgent.GetWeather]
end

{:ok, %{messages: messages}} = BeamWeaver.Examples.ReactAgent.invoke(%{messages: ["What's the weather in Nicosia?"]})

messages |> List.last() |> Message.text() |> IO.puts()
Support.assert_tools_called!(messages, ["get_weather"])
