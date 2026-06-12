alias BeamWeaver.Agent.HITL
alias BeamWeaver.Agent.Middleware.HumanInTheLoop
alias BeamWeaver.Checkpoint.ETS, as: CheckpointETS
alias BeamWeaver.Core.ChatModel
alias BeamWeaver.Core.Message
alias BeamWeaver.Core.Tool

defmodule BeamWeaver.Examples.HITLAgent.Model do
  @behaviour ChatModel

  defstruct []

  def invoke(%__MODULE__{}, messages, _opts) do
    if Enum.any?(messages, &match?(%Message{role: :tool}, &1)) do
      {:ok, Message.assistant("human reviewed")}
    else
      {:ok,
       Message.assistant("",
         tool_calls: [%{id: "call-lookup", name: "lookup", args: %{"query" => "docs"}}]
       )}
    end
  end
end

defmodule BeamWeaver.Examples.HITLAgent do
  use BeamWeaver.Agent

  model(%BeamWeaver.Examples.HITLAgent.Model{})

  def tools do
    [
      Tool.from_function!(
        name: "lookup",
        description: "Lookup docs",
        input_schema: %{"type" => "object", "required" => ["query"]},
        handler: fn %{"query" => query}, _opts -> "lookup:#{query}" end
      )
    ]
  end

  tools do
    include(__MODULE__.tools())
  end

  middleware do
    use HumanInTheLoop, interrupt_on: %{"lookup" => true}, tools: __MODULE__.tools()
  end
end

checkpointer = CheckpointETS.new()
config = %{"configurable" => %{"thread_id" => "example-hitl"}}

{:interrupted, interrupt} =
  BeamWeaver.Examples.HITLAgent.invoke(%{messages: [Message.user("lookup")]},
    checkpointer: checkpointer,
    config: config
  )

{:ok, review} = HITL.from_interrupt(interrupt)
IO.puts(hd(review.action_requests).name)

{:ok, %{messages: messages}} =
  BeamWeaver.Examples.HITLAgent.resume_review([HITL.decision(:respond, message: "approved")],
    checkpointer: checkpointer,
    config: config
  )

messages |> List.last() |> Message.text() |> IO.puts()
