alias BeamWeaver.Agent.StructuredOutput
alias BeamWeaver.Core.ChatModel
alias BeamWeaver.Core.Message

defmodule BeamWeaver.Examples.StructuredOutputAgent.Model do
  @behaviour ChatModel

  defstruct []

  def invoke(%__MODULE__{}, _messages, _opts) do
    {:ok,
     Message.assistant("",
       tool_calls: [
         %{id: "call-answer", name: "answer_schema", args: %{"answer" => "42"}}
       ]
     )}
  end
end

defmodule BeamWeaver.Examples.StructuredOutputAgent do
  use BeamWeaver.Agent

  model(%BeamWeaver.Examples.StructuredOutputAgent.Model{})

  response_format(
    StructuredOutput.tool(%{
      "title" => "answer_schema",
      "type" => "object",
      "required" => ["answer"],
      "properties" => %{"answer" => %{"type" => "string"}}
    })
  )
end

{:ok, %{structured_response: %{"answer" => answer}}} =
  BeamWeaver.Examples.StructuredOutputAgent.invoke(%{messages: [Message.user("answer")]})

IO.puts(answer)
