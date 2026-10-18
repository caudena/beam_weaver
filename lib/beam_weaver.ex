defmodule BeamWeaver do
  @moduledoc """
  BeamWeaver builds LLM agents and workflows in Elixir.

  ```elixir
  defmodule MyApp.SupportAgent do
    use BeamWeaver.Agent

    model "fake:chat", responses: ["Order A-1001 shipped on Monday."]
    system_prompt "You are Acme's support agent."
  end

  {:ok, result} = MyApp.SupportAgent.invoke(%{messages: ["Where is my order A-1001?"]})
  result.messages |> List.last() |> BeamWeaver.Core.Message.text()
  #=> "Order A-1001 shipped on Monday."
  ```

  Where to start:

    * `BeamWeaver.Agent` - agent modules: a model, instructions and tools.
    * `BeamWeaver.Tool` - tools the model can call.
    * `BeamWeaver.Graph` - workflows built from nodes and edges.
    * `BeamWeaver.Models` - models from any provider, named `"provider:model"`.
    * `BeamWeaver.Checkpoint` and `BeamWeaver.Memory` - threads and long-term memory.
    * `BeamWeaver.Stream` - events while a run progresses.

  The [Quickstart](quickstart.md) makes a real OpenAI or Google call.
  [Build an Agent](tutorial.md) adds a tool and conversation history.
  The scripted model above is for deterministic tests; [Testing](testing.md)
  explains how to assert tool calls and results without a network request.
  """
end
