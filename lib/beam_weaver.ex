defmodule BeamWeaver do
  @moduledoc ~S"""
  Agents, tools and durable graph workflows for Elixir applications.

  Start with [Installation](installation.md), then run a real provider call:

  ```elixir
  defmodule MyApp.FirstAgent do
    use BeamWeaver.Agent
    model "openai:gpt-5.4-mini", max_tokens: 128, timeout: 60_000
    system_prompt "Explain concepts briefly."
  end

  {:ok, result} = MyApp.FirstAgent.invoke(%{messages: ["What is parcel tracking?"]})
  answer = result.messages |> List.last() |> BeamWeaver.Core.Message.text()
  true = byte_size(answer) > 0
  ```

  Configure OpenAI in the consuming application's runtime configuration before
  invocation. Construction/compilation alone does not authenticate a provider.

  ## Choose an interface

  * `BeamWeaver.Agent`: model-selected tool loops and capability declarations.
  * `BeamWeaver.Tool` and `BeamWeaver.Schema`: action inputs and typed answers.
  * `BeamWeaver.Graph`: explicit nodes, routes, joins and state channels.
  * `BeamWeaver.Models`: chat, embedding and decision model constructors.
  * `BeamWeaver.Checkpoint` and `BeamWeaver.Memory`: thread and cross-thread state.
  * `BeamWeaver.Stream` and `BeamWeaver.Tracing`: progress and execution evidence.

  The [support-agent tutorial](tutorial.md) introduces tools and conversation
  history. [Production Integration](going_to_production.md) explains resource
  ownership, authorization, budgets and recovery. Scripted models belong in
  [application tests](testing.md).
  """
end
