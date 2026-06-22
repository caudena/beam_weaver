Code.require_file("support.exs", __DIR__)

alias BeamWeaver.Core.Message
alias BeamWeaver.Examples.Support

defmodule BeamWeaver.Examples.StructuredOutputAgent.AnswerSchema do
  use BeamWeaver.Schema

  title("answer_schema")
  strict(true)

  field(:answer, :string, required: true)
end

defmodule BeamWeaver.Examples.StructuredOutputAgent do
  use BeamWeaver.Agent

  name("structured_output_agent")
  model(Support.model())

  response_schema(BeamWeaver.Examples.StructuredOutputAgent.AnswerSchema,
    name: "answer_schema",
    strategy: :auto
  )
end

{:ok, %{structured_response: %{"answer" => answer}}} =
  BeamWeaver.Examples.StructuredOutputAgent.invoke(%{
    messages: [Message.user(~s(What is 2 + 2? Return JSON with answer as the string "4".))]
  })

IO.puts(answer)
