defmodule BeamWeaver.TestSupport.Conformance.AgentCaseFixture do
  use BeamWeaver.Agent

  alias BeamWeaver.Core.ChatModel
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Tool

  defmodule Model do
    @behaviour ChatModel

    defstruct []

    @impl true
    def invoke(%__MODULE__{}, messages, _opts) do
      case Enum.find(messages, &match?(%Message{role: :tool}, &1)) do
        %Message{content: content} ->
          {:ok,
           Message.assistant("final: #{content}",
             usage_metadata: %{input_tokens: 1, output_tokens: 1, total_tokens: 2}
           )}

        nil ->
          {:ok,
           Message.assistant("",
             usage_metadata: %{input_tokens: 1, output_tokens: 0, total_tokens: 1},
             tool_calls: [%{id: "call_echo", name: "echo", args: %{"value" => "standard"}}]
           )}
      end
    end
  end

  model(%Model{})

  tools([
    Tool.from_function!(
      name: "echo",
      description: "Echo",
      input_schema: %{
        "type" => "object",
        "required" => ["value"],
        "properties" => %{"value" => %{"type" => "string"}}
      },
      handler: fn %{"value" => value}, _opts -> value end
    )
  ])
end

defmodule BeamWeaver.TestSupport.Conformance.AgentCaseTest do
  use BeamWeaver.TestSupport.Conformance.AgentCase,
    agent: BeamWeaver.TestSupport.Conformance.AgentCaseFixture,
    input: %{messages: [BeamWeaver.Core.Message.user("hello")]},
    capabilities: [:tools, :streaming, :checkpointing, :usage_metadata]
end
