# Workflow Patterns

Choose the smallest workflow that makes your application's decisions explicit.
A pipeline, router or bounded review loop often needs less autonomy than a
general agent. Graph nodes can combine real model calls with deterministic
validation and data access.

Complete [Installation](installation.md). The live examples below use OpenAI
and facts supplied in the input; they do not invent a customer's order status.


Run this page’s examples in order in one IEx session; later blocks reuse the modules and values defined earlier.

## Prompt chaining

Separate extraction from writing so application code can validate the
intermediate result. This module performs two real calls:

```elixir
defmodule MyApp.TicketWorkflow do
  use BeamWeaver.Graph
  alias BeamWeaver.Core.{ChatModel, Message}

  graph do
    node :summarize, &__MODULE__.summarize/1, timeout: 70_000
    node :draft, &__MODULE__.draft/1, timeout: 70_000
    edge start(), :summarize
    edge :summarize, :draft
    edge :draft, finish()
  end

  def summarize(%{ticket: ticket}) do
    with {:ok, reply} <-
           ChatModel.invoke(model(), "Summarize this request in one sentence, preserving the order ID: #{ticket}") do
      %{summary: Message.text(reply)}
    end
  end

  def draft(%{summary: summary, facts: facts}) do
    with {:ok, reply} <-
           ChatModel.invoke(model(), [
             Message.system(
               "Write a brief customer reply. Use only supplied facts. Include the order ID and delivery day."
             ),
             Message.user("Request: #{summary}\nVerified facts: #{facts}")
           ]) do
      %{reply: Message.text(reply)}
    end
  end

  defp model, do: BeamWeaver.Models.init_chat_model!("openai:gpt-5.4-mini", max_tokens: 256, timeout: 60_000)
end

{:ok, result} =
  MyApp.TicketWorkflow.invoke(%{
    ticket: "Where is my package A-1001?",
    facts: "Order A-1001 arrives Thursday."
  })

true = result.summary =~ "A-1001"
true = result.reply =~ "A-1001"
true = String.downcase(result.reply) =~ "thursday"
```

A node propagates provider errors rather than converting them into successful
text. Add a validation node or guarded edge between stages when missing facts
should stop the pipeline. For machine routing, prefer [structured output](structured_output.md)
to parsing arbitrary prose.

## Routing

A classifier writes a constrained label; guarded edges select the handler.
Choose an explicit fallback such as manual review for an invalid/unknown
label. Do not silently route every unexpected model answer to a business
category. Validate confidence and required facts where your use case needs them.

The [Graph DSL](graphs.md#build-and-run-a-graph) demonstrates routing without a
model. Substitute a structured classifier only when the input requires one.
Decision models are another option; see [Models](models.md#decision-models).

Use a schema for the classifier and give unexpected/uncertain input an explicit manual-review label:

```elixir
defmodule MyApp.TicketTeam do
  use BeamWeaver.Schema
  field :team, :string, enum: ["billing", "shipping", "manual"]
end

defmodule MyApp.TeamClassifier do
  use BeamWeaver.Agent
  model "openai:gpt-5.4-mini", max_tokens: 256, timeout: 60_000

  system_prompt "Classify the request. Payment/refund questions are billing, delivery questions are shipping. Use manual when neither fits."

  response_schema MyApp.TicketTeam
end

alias BeamWeaver.Graph
alias BeamWeaver.Graph.Compiled

routing =
  Graph.new()
  |> Graph.add_node(:classify, fn %{ticket: ticket} ->
    with {:ok, answer} <- MyApp.TeamClassifier.invoke(%{messages: [ticket]}),
         do: %{team: answer.structured_response["team"]}
  end)
  |> Graph.add_node(:billing, fn _ -> %{queue: "billing"} end)
  |> Graph.add_node(:shipping, fn _ -> %{queue: "shipping"} end)
  |> Graph.add_node(:manual, fn _ -> %{queue: "manual"} end)
  |> Graph.add_edge(Graph.start(), :classify)
  |> Graph.add_edge(:classify, :billing, when: %{team: "billing"})
  |> Graph.add_edge(:classify, :shipping, when: %{team: "shipping"})
  |> Graph.add_edge(:classify, :manual, default: true)
  |> Graph.add_edge(:billing, Graph.end_node())
  |> Graph.add_edge(:shipping, Graph.end_node())
  |> Graph.add_edge(:manual, Graph.end_node())
  |> Graph.compile!()

{:ok, %{team: "billing", queue: "billing"}} =
  Compiled.invoke(routing, %{ticket: "I was charged twice. Please review the duplicate payment."})
```

## Parallelization

Run independent checks concurrently and join before deciding. Each branch
should write a different key or contribute through a reducer. The join must
wait for every required check; a successful tone check cannot stand in for a
failed policy check.

Use a map keyed by check name to preserve provenance. Do not assume several
model opinions constitute independent factual evidence. Supply source facts
to each reviewer and define how disagreement affects the workflow.
[Graph State](graph_state.md) shows a complete parallel merge.

These independent checks are ordinary application rules. A reducer collects their named results and a join waits for both:

```elixir
defmodule MyApp.ParallelReview do
  use BeamWeaver.Graph

  graph do
    state do
      channel :checks, merge: :map
    end

    node :order_id, fn %{draft: text} -> %{checks: %{order_id: text =~ "A-1001"}} end
    node :delivery, fn %{draft: text} -> %{checks: %{delivery: text =~ "Thursday"}} end
    node :decide, fn %{checks: checks} -> %{approved: Enum.all?(checks, fn {_, ok} -> ok end)} end
    edge start(), :order_id
    edge start(), :delivery
    join [:order_id, :delivery], :decide
    edge :decide, finish()
  end
end

{:ok, %{approved: false, checks: %{order_id: true, delivery: false}}} =
  MyApp.ParallelReview.invoke(%{draft: "A-1001 has shipped."})

{:ok, %{approved: true}} = MyApp.ParallelReview.invoke(%{draft: "A-1001 arrives Thursday."})
```

## Orchestrator-workers

When task count is dynamic, dispatch with `Send`. This real-model example
summarizes two supplied records and retains the source ID with each answer:

```elixir
alias BeamWeaver.Graph
alias BeamWeaver.Graph.{Compiled, Send}
alias BeamWeaver.Core.{ChatModel, Message}
model = BeamWeaver.Models.init_chat_model!("openai:gpt-5.4-mini", max_tokens: 128, timeout: 60_000)

workers =
  Graph.new()
  |> Graph.add_reducer(:summaries, &Kernel.++/2)
  |> Graph.add_node(
    :dispatch,
    fn %{records: records} ->
      Enum.map(records, &%Send{node: :summarize, update: %{record: &1}})
    end,
    destinations: [:summarize]
  )
  |> Graph.add_node(
    :summarize,
    fn %{record: record} ->
      with {:ok, reply} <- ChatModel.invoke(model, "Summarize only this fact briefly: #{record.text}") do
        %{summaries: [%{id: record.id, text: Message.text(reply)}]}
      end
    end,
    timeout: 70_000
  )
  |> Graph.add_edge(Graph.start(), :dispatch)
  |> Graph.add_edge(:summarize, Graph.end_node())
  |> Graph.compile!()

{:ok, batch} =
  Compiled.invoke(workers, %{
    records: [%{id: "A-1001", text: "Delivery is Thursday."}, %{id: "A-1002", text: "Delivery is Friday."}],
    summaries: []
  })

["A-1001", "A-1002"] = batch.summaries |> Enum.map(& &1.id) |> Enum.sort()
true = Enum.all?(batch.summaries, &(byte_size(&1.text) > 0))
```

A worker can instead be an agent with tools. Bound task count and concurrency
at the application boundary so a model-generated plan cannot create unbounded
provider work. [Subagents](subagents.md) offers model-selected delegation;
`Send` expresses application-selected work.

## Evaluator-optimizer

A writer produces a candidate; an evaluator returns an explicit accepted or
revision-required result. A guarded back-edge carries feedback to the writer.
Bound revisions with `max_runs:` and the whole run with a timeout.

Require an explicit accepted verdict. Malformed output or an exhausted budget
must not be treated as acceptance. Preserve the final verdict alongside the
candidate so downstream code knows whether it met the criteria. Structured
schemas help represent verdict, feedback and evidence consistently.

Begin with an incomplete draft, validate required facts in application code, and ask a real model to revise it. Acceptance remains an explicit result:

```elixir
alias BeamWeaver.Graph
alias BeamWeaver.Graph.Compiled
alias BeamWeaver.Core.{ChatModel, Message}
model = BeamWeaver.Models.init_chat_model!("openai:gpt-5.4-mini", max_tokens: 256, timeout: 60_000)

improve =
  Graph.new()
  |> Graph.add_node(:evaluate, fn %{draft: draft} ->
    accepted = draft =~ "A-1001" and String.downcase(draft) =~ "thursday"
    %{verdict: if(accepted, do: :accept, else: :revise), feedback: "Include order A-1001 and delivery Thursday."}
  end)
  |> Graph.add_node(
    :write,
    fn state ->
      with {:ok, reply} <-
             ChatModel.invoke(
               model,
               "Revise this customer reply using only these facts: A-1001 arrives Thursday. #{state.feedback} Draft: #{state.draft}"
             ),
           do: %{draft: Message.text(reply)}
    end,
    timeout: 70_000
  )
  |> Graph.add_edge(Graph.start(), :evaluate)
  |> Graph.add_edge(:evaluate, :write, when: %{verdict: :revise}, max_runs: 3)
  |> Graph.add_edge(:evaluate, Graph.end_node(), default: true)
  |> Graph.add_edge(:write, :evaluate)
  |> Graph.compile!()

{:ok, result} = Compiled.invoke(improve, %{draft: "Your order has shipped."}, run_timeout: 240_000)
:accept = result.verdict
true = result.draft =~ "A-1001"
true = String.downcase(result.draft) =~ "thursday"
```

## An agent is a graph

An agent coordinates model turns and tool execution with additional hooks,
state management, structured output and review. Use `use BeamWeaver.Agent`
for that standard loop. Building it by hand means owning tool correlation,
error handling, persistence and termination yourself.

An agent module can be one node in a workflow. [Subgraphs](subgraphs.md#agents-as-subgraphs)
shows how to map the parent input and extract the agent's answer while keeping
nested lifecycle behavior.

For advanced orchestration, the same model/tool cycle can be built explicitly. This example uses a real provider and a local lookup:

```elixir
alias BeamWeaver.Agent.ToolNode
alias BeamWeaver.{Models, Graph}
alias BeamWeaver.Graph.Compiled
alias BeamWeaver.Core.{ChatModel, Message}

defmodule MyApp.Tools.LookupOrder do
  use BeamWeaver.Tool

  name "lookup_order"
  description "Look up the shipping status of an order by its id."

  schema do
    field :order_id, :string, description: "The order id"
  end

  @impl true
  def invoke(_tool, %{"order_id" => order_id}, _opts), do: {:ok, "Order #{order_id} shipped on Monday."}
end

model = Models.init_chat_model!("openai:gpt-5.4-mini", max_tokens: 256, timeout: 60_000)

call_model = fn %{messages: messages} ->
  {:ok, reply} = ChatModel.invoke(model, messages, tools: [MyApp.Tools.LookupOrder])
  %{messages: [reply]}
end

agent_loop =
  Graph.new(state_schema: BeamWeaver.Graph.Messages.state_schema())
  |> Graph.add_node(:model, call_model)
  |> Graph.add_node(:tools, ToolNode.new([MyApp.Tools.LookupOrder]))
  |> Graph.add_edge(Graph.start(), :model)
  |> Graph.add_edge(:model, :tools, when: fn %{messages: [reply]} -> reply.tool_calls != [] end)
  |> Graph.add_edge(:model, Graph.end_node(), default: true)
  |> Graph.add_edge(:tools, :model)
  |> Graph.compile!()

{:ok, state} =
  Compiled.invoke(agent_loop, %{messages: ["Use lookup_order to check A-1001, then report its shipping status."]})

true = Enum.any?(state.messages, &(&1.role == :tool and &1.name == "lookup_order"))
true = Message.text(List.last(state.messages)) =~ "Monday"
```

## Choosing a pattern

| Pattern | Choose it for |
| --- | --- |
| Chaining | Fixed stages with intermediate checks |
| Routing | Distinct handlers selected by validated input |
| Parallel checks | Independent work with a clear aggregation rule |
| Orchestrator-workers | A dynamic but bounded set of subtasks |
| Evaluator-optimizer | Measurable acceptance criteria and bounded revisions |
| Agent | Model-selected action sequences |
