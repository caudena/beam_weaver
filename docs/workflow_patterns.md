# Workflow Patterns

These are the common ways to combine model calls and plain code in a
[graph](graphs.md): prompt chaining, routing, parallel calls, an orchestrator
with workers, an evaluator-optimizer loop, and the agent loop itself. Use them
as starting points when your steps are known in advance and an
[agent](agents.md) alone would leave too much to the model.

Every example runs as is with scripted fake models. A fake model picks its
reply by how many answers the conversation already holds, so a fresh prompt
always gets the first scripted reply; that is why each role here has its own
model. With a provider model, one model can play every role. The examples
share this setup:

```elixir
alias BeamWeaver.Core.{ChatModel, Message}
alias BeamWeaver.Graph
alias BeamWeaver.Graph.{Command, Compiled, Send}
alias BeamWeaver.Models

ask = fn model, prompt ->
  {:ok, reply} = ChatModel.invoke(model, prompt)
  Message.text(reply)
end
```

## Prompt chaining

Split a task into steps where each model call works on the output of the one
before. Between steps, plain code can check the result and stop the chain:

```elixir
summarizer = Models.init_chat_model!("fake:chat", responses: ["Ada asks where order A-1001 is."])
writer = Models.init_chat_model!("fake:chat", responses: ["Hi Ada, order A-1001 shipped on Monday."])

summarize = fn %{ticket: ticket} -> %{summary: ask.(summarizer, "Summarize in one line: #{ticket}")} end
draft = fn %{summary: summary} -> %{reply: ask.(writer, "Write a short, friendly reply to: #{summary}")} end
ask_for_order = fn _state -> %{reply: "Could you send me your order number?"} end

chain =
  Graph.new()
  |> Graph.add_node(:summarize, summarize)
  |> Graph.add_node(:draft, draft)
  |> Graph.add_node(:ask_for_order, ask_for_order)
  |> Graph.add_edge(Graph.start(), :summarize)
  |> Graph.add_edge(:summarize, :draft, when: fn %{summary: summary} -> summary =~ ~r/A-\d+/ end)
  |> Graph.add_edge(:summarize, :ask_for_order, default: true)
  |> Graph.add_edge(:draft, Graph.end_node())
  |> Graph.add_edge(:ask_for_order, Graph.end_node())
  |> Graph.compile!()

{:ok, state} = Compiled.invoke(chain, %{ticket: "hi!! where is my package A-1001, ordered last week"})
state.reply
#=> "Hi Ada, order A-1001 shipped on Monday."
```

The gate is an ordinary `when:` function: the chain drafts a reply only when
the summary names an order.

## Routing

A classifier decides what kind of input this is, and each kind goes to its
own handler, with its own prompt, model or agent:

```elixir
router = Models.init_chat_model!("fake:chat", responses: ["billing"])
billing = Models.init_chat_model!("fake:chat", responses: ["Refunds reach your card in 5 business days."])
shipping = Models.init_chat_model!("fake:chat", responses: ["Your parcel is with the carrier."])

classify = fn %{ticket: ticket} ->
  team = ask.(router, "Which team should answer, billing or shipping? #{ticket}")
  %{team: team |> String.trim() |> String.downcase()}
end

answer_as = fn team, model ->
  fn %{ticket: ticket} -> %{reply: ask.(model, "As Acme #{team}, answer: #{ticket}")} end
end

routing =
  Graph.new()
  |> Graph.add_node(:classify, classify)
  |> Graph.add_node(:billing, answer_as.("billing", billing))
  |> Graph.add_node(:shipping, answer_as.("shipping", shipping))
  |> Graph.add_edge(Graph.start(), :classify)
  |> Graph.add_edge(:classify, :billing, when: %{team: "billing"})
  |> Graph.add_edge(:classify, :shipping, default: true)
  |> Graph.add_edge(:billing, Graph.end_node())
  |> Graph.add_edge(:shipping, Graph.end_node())
  |> Graph.compile!()

{:ok, state} = Compiled.invoke(routing, %{ticket: "When will my refund for A-1001 arrive?"})
{state.team, state.reply}
#=> {"billing", "Refunds reach your card in 5 business days."}
```

The default edge also catches a label the model made up. With a provider
model, ask for [structured output](structured_output.md) so the label is
always one you expect.

## Parallelization

Run independent model calls at the same time and combine their results. Here
three reviewers check a draft reply in parallel, and a join waits for all of
them:

```elixir
tone = Models.init_chat_model!("fake:chat", responses: ["pass"])
facts = Models.init_chat_model!("fake:chat", responses: ["pass"])
policy = Models.init_chat_model!("fake:chat", responses: ["fail: it promises a date"])

check = fn aspect, model ->
  fn %{draft: draft} ->
    verdict = ask.(model, "Check the #{aspect} of this reply. Answer pass or fail: <why>.\n#{draft}")
    %{checks: %{aspect => verdict}}
  end
end

decide = fn %{checks: checks} ->
  failed = for {aspect, "fail" <> _reason} <- checks, do: aspect
  %{approved: failed == [], failed: failed}
end

review =
  Graph.new()
  |> Graph.add_reducer(:checks, &Map.merge/2)
  |> Graph.add_node(:tone, check.(:tone, tone))
  |> Graph.add_node(:facts, check.(:facts, facts))
  |> Graph.add_node(:policy, check.(:policy, policy))
  |> Graph.add_node(:decide, decide)
  |> Graph.add_edge(Graph.start(), :tone)
  |> Graph.add_edge(Graph.start(), :facts)
  |> Graph.add_edge(Graph.start(), :policy)
  |> Graph.add_join([:tone, :facts, :policy], :decide)
  |> Graph.add_edge(:decide, Graph.end_node())
  |> Graph.compile!()

{:ok, state} = Compiled.invoke(review, %{draft: "Your refund arrives tomorrow!", checks: %{}})
{state.approved, state.failed}
#=> {false, [:policy]}
```

The `checks` reducer merges the three parallel writes. The same shape works
for voting: ask several models, or one model several times, and let `decide`
count the answers.

## Orchestrator-workers

When the subtasks are only known at run time, an orchestrator plans them and
sends each one to a worker with `Send`. A reducer collects what the workers
return, and a final step combines it:

```elixir
planner = Models.init_chat_model!("fake:chat", responses: ["A-1001\nA-1002"])
worker = Models.init_chat_model!("fake:chat", responses: ["shipped on Monday"])
writer = Models.init_chat_model!("fake:chat", responses: ["Hi Ada, both of your orders shipped on Monday."])

plan = fn %{ticket: ticket} ->
  order_ids = ask.(planner, "List the order ids in this ticket, one per line: #{ticket}")
  order_ids = String.split(order_ids, "\n", trim: true)
  sends = Enum.map(order_ids, &%Send{node: :check_order, update: %{order_id: &1}})
  %Command{update: %{order_ids: order_ids}, goto: sends}
end

check_order = fn %{order_id: id} ->
  %{findings: ["#{id}: #{ask.(worker, "What is the status of order #{id}?")}"]}
end

write_reply = fn %{findings: findings} ->
  %{reply: ask.(writer, "Reply to Ada using these findings:\n" <> Enum.join(findings, "\n"))}
end

orchestrator =
  Graph.new()
  |> Graph.add_reducer(:findings, &(&1 ++ &2))
  |> Graph.add_node(:plan, plan, destinations: [:check_order])
  |> Graph.add_node(:check_order, check_order)
  |> Graph.add_node(:write_reply, write_reply)
  |> Graph.add_edge(Graph.start(), :plan)
  |> Graph.add_edge(:check_order, :write_reply)
  |> Graph.add_edge(:write_reply, Graph.end_node())
  |> Graph.compile!()

{:ok, state} = Compiled.invoke(orchestrator, %{ticket: "Where are A-1001 and A-1002?", findings: []})
{state.findings, state.reply}
#=> {["A-1001: shipped on Monday", "A-1002: shipped on Monday"],
#    "Hi Ada, both of your orders shipped on Monday."}
```

The workers run in parallel, one process each, and `write_reply` runs once,
after all of them. In an application a worker is often a whole agent with
tools, called from the node.

## Evaluator-optimizer

One model writes, another reviews and gives feedback, and the graph loops
until the reviewer accepts or the loop limit is reached:

```elixir
writer =
  Models.init_chat_model!("fake:chat",
    responses: ["Your order shipped.", "Your order A-1001 shipped on Monday and arrives on Thursday."]
  )

reviewer =
  Models.init_chat_model!("fake:chat",
    responses: ["REVISE: Name the order and say when it arrives.", "ACCEPT"]
  )

write = fn %{writer_chat: chat} ->
  {:ok, draft} = ChatModel.invoke(writer, chat)
  %{draft: Message.text(draft), writer_chat: [draft]}
end

evaluate = fn %{draft: draft, review_chat: chat} ->
  request = Message.user("Review this reply to Ada. Answer ACCEPT or REVISE: <feedback>.\n#{draft}")
  {:ok, verdict} = ChatModel.invoke(reviewer, chat ++ [request])

  case Message.text(verdict) do
    "REVISE: " <> feedback ->
      %{verdict: :revise, review_chat: [request, verdict], writer_chat: [Message.user(feedback)]}

    _accept ->
      %{verdict: :accept, review_chat: [request, verdict]}
  end
end

improve =
  Graph.new()
  |> Graph.add_reducer(:writer_chat, &(&1 ++ &2))
  |> Graph.add_reducer(:review_chat, &(&1 ++ &2))
  |> Graph.add_node(:write, write)
  |> Graph.add_node(:evaluate, evaluate)
  |> Graph.add_edge(Graph.start(), :write)
  |> Graph.add_edge(:write, :evaluate)
  |> Graph.add_edge(:evaluate, :write, when: %{verdict: :revise}, max_runs: 3)
  |> Graph.add_edge(:evaluate, Graph.end_node(), default: true)
  |> Graph.compile!()

task = Message.user("Tell Ada about order A-1001: shipped Monday, arrives Thursday.")
{:ok, state} = Compiled.invoke(improve, %{writer_chat: [task], review_chat: []})
{state.verdict, state.draft}
#=> {:accept, "Your order A-1001 shipped on Monday and arrives on Thursday."}
```

Each model keeps its own conversation in the state: the writer sees its last
draft and the feedback, and the reviewer sees what it asked for before.
`max_runs: 3` caps the revisions of each run; after that the default edge
ends the run with the last draft.

## An agent is a graph

An agent is the loop below: a model node that may ask for tools, and a tool
node that runs them and goes back to the model. Building it by hand shows the
moving parts:

```elixir
alias BeamWeaver.Graph.Nodes.ToolNode
alias BeamWeaver.Models.FakeChatModel

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

model =
  Models.init_chat_model!("fake:chat",
    responses: [
      FakeChatModel.tool_call("lookup_order", %{"order_id" => "A-1001"}),
      "Your order A-1001 shipped on Monday."
    ]
  )

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

{:ok, state} = Compiled.invoke(agent_loop, %{messages: ["Where is my order A-1001?"]})
Enum.map(state.messages, & &1.role)
#=> [:user, :assistant, :tool, :assistant]
```

`use BeamWeaver.Agent` builds this loop for you, and adds system prompts,
middleware, structured output and human review around it. Its compiled graph
has the same two nodes:

```elixir
defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  model "fake:chat", responses: ["Your order A-1001 shipped on Monday."]
  tools [MyApp.Tools.LookupOrder]
end

{:ok, support_graph} = BeamWeaver.Agent.compiled_graph(MyApp.SupportAgent)
support_graph |> Compiled.get_graph() |> Map.fetch!(:nodes) |> Map.keys()
#=> ["model", "tools"]
```

Because an agent is a graph, it can also be one node of a bigger workflow,
added as it is with `Graph.add_node(graph, :support, MyApp.SupportAgent)`;
see [Subgraphs](subgraphs.md#agents-as-subgraphs).

## Choosing a pattern

| Pattern | Use it when | Built with |
| --- | --- | --- |
| Prompt chaining | A task splits into fixed steps you can check in between. | Edges and `when:` gates |
| Routing | Inputs fall into kinds that need different handling. | A classifier node and guarded edges or `Command` |
| Parallelization | Checks or subtasks don't depend on each other, or you want several votes. | Edges from one node, `Graph.add_join/4`, reducers |
| Orchestrator-workers | The subtasks are only known at run time. | `Send` and a reducer |
| Evaluator-optimizer | Clear criteria exist and feedback improves the result. | A loop with `max_runs:` |
| Agent | The model should choose the steps. | `use BeamWeaver.Agent` |

## Reference

- [`BeamWeaver.Graph`](https://hexdocs.pm/beam_weaver/BeamWeaver.Graph.html): build and compile graphs
- [`BeamWeaver.Graph.Send`](https://hexdocs.pm/beam_weaver/BeamWeaver.Graph.Send.html): send work to a node, once per item
- [`BeamWeaver.Graph.Command`](https://hexdocs.pm/beam_weaver/BeamWeaver.Graph.Command.html): update the state and choose the next nodes
- [`BeamWeaver.Graph.Nodes.ToolNode`](https://hexdocs.pm/beam_weaver/BeamWeaver.Graph.Nodes.ToolNode.html): run the tool calls of the last model message
- [`BeamWeaver.Core.ChatModel`](https://hexdocs.pm/beam_weaver/BeamWeaver.Core.ChatModel.html): call a chat model
- [`BeamWeaver.Models.FakeChatModel`](https://hexdocs.pm/beam_weaver/BeamWeaver.Models.FakeChatModel.html): scripted model for examples and tests
