alias BeamWeaver.Core.ChatModel
alias BeamWeaver.Core.Message
alias BeamWeaver.Core.Tool

defmodule BeamWeaver.Examples.ReactAgent.Model do
  @behaviour ChatModel

  defstruct []

  def invoke(%__MODULE__{}, messages, _opts) do
    if Enum.any?(messages, &match?(%Message{role: :tool}, &1)) do
      {:ok, Message.assistant("weather checked")}
    else
      {:ok,
       Message.assistant("",
         tool_calls: [%{id: "call-weather", name: "weather", args: %{"city" => "Nicosia"}}]
       )}
    end
  end
end

defmodule BeamWeaver.Examples.ReactAgent do
  use BeamWeaver.Agent

  model(%BeamWeaver.Examples.ReactAgent.Model{})

  tools do
    tool(
      Tool.from_function!(
        name: "weather",
        description: "Get weather",
        input_schema: %{"type" => "object", "required" => ["city"]},
        handler: fn %{"city" => city}, _opts -> "sunny in #{city}" end
      )
    )
  end
end

{:ok, %{messages: messages}} =
  BeamWeaver.Examples.ReactAgent.invoke(%{messages: [Message.user("check weather")]})

messages |> List.last() |> Message.text() |> IO.puts()
