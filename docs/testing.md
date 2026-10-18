# Testing

BeamWeaver tests run offline: a scripted fake model stands in for the
provider, and tools, middleware hooks and graph nodes are functions you call
directly. Use the patterns on this page in ExUnit to test agents and
workflows quickly, without an API key or a network connection.

```elixir
import ExUnit.Assertions

alias BeamWeaver.Core.Message

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

defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  alias BeamWeaver.Models.FakeChatModel

  model "fake:chat",
    responses: [
      FakeChatModel.tool_call("lookup_order", %{"order_id" => "A-1001"}),
      "Your order A-1001 shipped on Monday.",
      "You're welcome, Ada!"
    ]

  system_prompt "You are Acme's support agent. Look orders up before you answer."
  tools [MyApp.Tools.LookupOrder]
end

{:ok, result} = MyApp.SupportAgent.invoke(%{messages: ["Where is my order A-1001?"]})

assert [_question, %{tool_calls: [call]}, tool_result, answer] = result.messages
{call.args, Message.text(tool_result), Message.text(answer)}
#=> {%{"order_id" => "A-1001"}, "Order A-1001 shipped on Monday.", "Your order A-1001 shipped on Monday."}
```

The script fixes what the model says, so the test checks everything around
it: the tool ran with the model's arguments, its result reached the
conversation, and the answer came back. [ExUnit tips](#exunit-tips) shows a
whole test module.

## Script the model

Each entry of `responses:` is one model turn: a text, a
`FakeChatModel.tool_call/2` or `FakeChatModel.tool_calls/1` turn, a
`FakeChatModel.final/1` structured answer, or a message (see
[Fake models](models.md#fake-models)). The fake model reads the turn from the
conversation: each reply records its entry's position in `metadata.fake_turn`,
and the next reply takes the next entry. Within one run the entries play in
order, and the last one repeats once the script runs out.

A new conversation starts again at the first entry, while a conversation that
continues on its thread continues the script. Here the third entry answers a
follow-up on the same thread:

```elixir
saver = BeamWeaver.Checkpoint.ETS.new()
opts = [checkpointer: saver, config: %{"configurable" => %{"thread_id" => "ticket-42"}}]

{:ok, _first} = MyApp.SupportAgent.invoke(%{messages: ["Where is my order A-1001?"]}, opts)
{:ok, second} = MyApp.SupportAgent.invoke(%{messages: ["Thanks!"]}, opts)

for %{role: :assistant} = reply <- second.messages, do: {reply.metadata.fake_turn, Message.text(reply)}
#=> [{0, ""}, {1, "Your order A-1001 shipped on Monday."}, {2, "You're welcome, Ada!"}]
```

Assistant messages you pass in yourself count as turns already played. When
the script and the conversation get out of step, for example because
structured output added a model call, `fake_turn` shows which entry produced
which reply.

## Check what the model received

With `parent:`, the fake model sends `{:fake_chat_model_call, messages, opts}`
to a process on every call. `messages` is what a provider would receive,
system prompt first, and `opts[:tools]` holds the tools on offer, so you can
test what prompts and middleware do to a request:

```elixir
defmodule MyApp.PlanAgent do
  use BeamWeaver.Agent

  alias BeamWeaver.Agent.Middleware.DynamicPrompt

  model BeamWeaver.Models.init_chat_model!("fake:chat", responses: ["Returns are free on Pro."], parent: self())
  tools [MyApp.Tools.LookupOrder]
  middleware [{DynamicPrompt, prompt: &__MODULE__.prompt/2}]

  def prompt(_state, runtime), do: "You are Acme's support agent. The customer is on the #{runtime.context.plan} plan."
end

{:ok, _result} = MyApp.PlanAgent.invoke(%{messages: ["Are returns free?"]}, context: %{plan: :pro})
assert_received {:fake_chat_model_call, [system, question], opts}
{Message.text(system), Message.text(question), Enum.map(opts[:tools], &BeamWeaver.Core.Tool.name/1)}
#=> {"You are Acme's support agent. The customer is on the pro plan.", "Are returns free?", ["lookup_order"]}
```

BeamWeaver evaluates the `model` line each time the agent runs, in the
process that calls `invoke/2`, so `self()` is your test, whether you write
`parent: self()` inside the `model` expression, as here, or after a model
string, as in `model "fake:chat", responses: [...], parent: self()`. To stream,
put `stream: true` after the expression, as in
`model BeamWeaver.Models.init_chat_model!("fake:chat", parent: self()), stream: true`
(inside `init_chat_model!/2` it has no effect); the model then sends
`{:fake_chat_model_stream, messages, opts}` instead.

## Simulate provider failures

`error:` makes every call fail, the way a provider outage would. Test what
your agent does then: the error that `invoke/2` returns, its retries, or its
fallback. Here the `parent:` messages show three attempts, the first call and
two retries:

```elixir
defmodule MyApp.OutageAgent do
  use BeamWeaver.Agent

  model BeamWeaver.Models.init_chat_model!("fake:chat",
          error: BeamWeaver.Core.Error.new(:rate_limit, "Too many requests"),
          parent: self()
        )

  middleware [{BeamWeaver.Agent.Middleware.ModelRetry, max_retries: 2}]
end

outcome = MyApp.OutageAgent.invoke(%{messages: ["Where is my order A-1001?"]})

for _attempt <- 1..3, do: assert_received({:fake_chat_model_call, _messages, _opts})
refute_received {:fake_chat_model_call, _messages, _opts}
outcome
#=> {:error, %BeamWeaver.Core.Error{type: :rate_limit, message: "Too many requests"}}
```

`ModelRetry` doesn't wait between attempts unless you set `initial_delay`; if
your agent sets one, read it from config so tests don't sleep. To test that a
backup model takes over, give `ModelFallback` a scripted fallback, as in
[Built-in Middleware](builtin_middleware.md#modelfallback).

## Test streaming

With `stream: true`, the fake model streams each reply word by word, as a
provider does. Without `live: true`, `stream_events/2` returns the events as a
list once the run ends, in the order a live stream sends them, so you can
assert on them directly:

```elixir
defmodule MyApp.StreamingAgent do
  use BeamWeaver.Agent

  model "fake:chat", stream: true, responses: ["Your order A-1001 shipped on Monday."]
end

{:ok, events} = MyApp.StreamingAgent.stream_events(%{messages: ["Where is my order A-1001?"]})

for %{event: %BeamWeaver.Stream.Events.Token{text: text}} <- events, do: text
#=> ["Your ", "order ", "A-1001 ", "shipped ", "on ", "Monday."]
```

Match `ToolStart`, `ToolFinish` and the other events the same way;
[Streaming](streaming.md) lists them. To test code that reads a live stream,
pass `live: true` and read the stream once with `Enum.to_list/1`: every pass
over a live stream starts a new run.

## Test tools and middleware

Tools and middleware hooks are plain functions, so most of their tests need
no agent. `BeamWeaver.Core.Tool.invoke/3` runs a tool with the arguments a
model would send, schema checks included:

```elixir
BeamWeaver.Core.Tool.invoke(MyApp.Tools.LookupOrder, %{})
#=> {:error, %BeamWeaver.Core.Error{type: :invalid_input, details: %{missing: ["order_id"]}}}
```

[Tools](tools.md#call-a-tool-directly) shows injected arguments, and
[Middleware](middleware.md#test-middleware) how to call each kind of hook.

## Emulate tools with side effects

Some tools act on the world: they issue refunds or send email. The
`ToolEmulator` middleware answers calls to the tools you name with a model
instead of running them, and the rest of the agent runs as usual. Script that
model too:

```elixir
defmodule MyApp.Tools.IssueRefund do
  use BeamWeaver.Tool

  name "issue_refund"
  description "Refund an order to the customer's card."

  schema do
    field :order_id, :string
  end

  # The real tool calls the payment provider.
  @impl true
  def invoke(_tool, _args, _opts), do: raise("tests must not issue real refunds")
end

defmodule MyApp.RefundAgent do
  use BeamWeaver.Agent

  alias BeamWeaver.Agent.Middleware.ToolEmulator
  alias BeamWeaver.Models.FakeChatModel

  model "fake:chat",
    responses: [FakeChatModel.tool_call("issue_refund", %{"order_id" => "A-1001"}), "Your refund is on its way."]

  tools [MyApp.Tools.LookupOrder, MyApp.Tools.IssueRefund]
  middleware [
    {ToolEmulator,
     tools: ["issue_refund"],
     model: BeamWeaver.Models.init_chat_model!("fake:chat", responses: ["Refunded A-1001."])}
  ]
end

{:ok, result} = MyApp.RefundAgent.invoke(%{messages: ["Please refund order A-1001."]})
refund = Enum.find(result.messages, &(&1.role == :tool))
{Message.text(refund), refund.metadata.emulated?}
#=> {"Refunded A-1001.", true}
```

Calls to other tools run for real. Without the `tools:` option every call is
emulated, and without `model:` each one returns `"Emulated response"`. The
emulating model receives the tool's name, description and arguments, so a real
model such as `"openai:gpt-5.4-mini"` can invent plausible results while the
real tool isn't built yet.

## Test graphs

A graph node is a function, and a graph module runs like an agent. This
triage graph classifies a ticket and pauses before a refund:

```elixir
defmodule MyApp.TicketTriage do
  use BeamWeaver.Graph

  alias BeamWeaver.Graph

  def graph do
    Graph.new()
    |> Graph.add_node(:classify, &classify/1)
    |> Graph.add_node(:approve, &approve/1)
    |> Graph.add_edge(Graph.start(), :classify)
    |> Graph.add_edge(:classify, :approve, when: %{category: :billing})
    |> Graph.add_edge(:approve, Graph.end_node())
  end

  def classify(%{subject: subject}), do: %{category: if(subject =~ ~r/refund/i, do: :billing, else: :general)}
  def approve(%{order_id: order_id}), do: %{approved: Graph.interrupt("Refund order #{order_id}?") == "yes"}
end

assert MyApp.TicketTriage.classify(%{subject: "Refund for A-1001"}) == %{category: :billing}

opts = [checkpointer: BeamWeaver.Checkpoint.ETS.new(), config: %{"configurable" => %{"thread_id" => "ticket-43"}}]
{:interrupted, interrupt} = MyApp.TicketTriage.invoke(%{subject: "Refund for A-1001", order_id: "A-1001"}, opts)
assert interrupt.value == "Refund order A-1001?"

MyApp.TicketTriage.resume("yes", opts)
#=> {:ok, %{category: :billing, approved: true}}
```

The test checks a node on its own, then runs the graph to the pause and
resumes it as a person would. Give nodes that call a model a scripted fake
model too, and see [Validate a graph](graphs.md#validate-a-graph) to check
a graph's shape.

## Fake embeddings

`"fake:embedding"` gives each text a fixed vector, so indexing and search run
without a provider. The vectors carry no meaning: test that your code embeds
the right texts and gets results back, not which result comes first. With the
fake, a question about refunds may well find the shipping text:

```elixir
alias BeamWeaver.VectorStore

{:ok, embeddings} = BeamWeaver.Models.init_embeddings("fake:embedding", parent: self())
store = VectorStore.ETS.new(embedding: embeddings)

{:ok, _ids} = VectorStore.add_texts(store, ["Refunds take 5 business days.", "Orders ship within 2 days."])
{:ok, results} = VectorStore.similarity_search(store, "How long do refunds take?", k: 1)

assert_received {:fake_embedding_query, "How long do refunds take?", _opts}
length(results)
#=> 1
```

`parent:` also reports `{:fake_embedding_documents, texts, opts}` for each
batch of documents. `dimensions:` sets the vector size (3 by default), and
`error:` makes every call fail. See [Retrieval](retrieval.md).

## ExUnit tips

A test module for the support agent, with its own saver for each test:

```elixir
defmodule MyApp.SupportAgentTest do
  use ExUnit.Case, async: true

  setup do
    saver = BeamWeaver.Checkpoint.ETS.new()
    %{opts: [checkpointer: saver, config: %{"configurable" => %{"thread_id" => "ticket-42"}}]}
  end

  test "answers a follow-up on the same thread", %{opts: opts} do
    {:ok, _first} = MyApp.SupportAgent.invoke(%{messages: ["Where is my order A-1001?"]}, opts)
    {:ok, second} = MyApp.SupportAgent.invoke(%{messages: ["Thanks!"]}, opts)

    assert BeamWeaver.Core.Message.text(List.last(second.messages)) == "You're welcome, Ada!"
  end
end
```

- Run agent tests with `async: true`: a fake model keeps no state between
  calls.
- Create savers and stores in `setup` and pass them with `checkpointer:` and
  `store:`. An ETS saver belongs to the test process that created it, so it
  is deleted when the test ends, and every test can use the same thread id.
- `parent:` messages wait in the test's mailbox; take them with
  `assert_received`, in the order the calls happened.

## Choose the model from config

Your application's agents use a real model, so tests need a way to swap it.
BeamWeaver evaluates the `model` declaration each time the agent runs, so it
can read the application environment:

<!-- snippet: compile -->
```elixir
defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  model Application.fetch_env!(:my_app, :support_model)
  system_prompt "You are Acme's support agent. Look orders up before you answer."
  tools [MyApp.Tools.LookupOrder]
end
```

```elixir
# config/config.exs
config :my_app, :support_model, "anthropic:claude-haiku-4-5"

# config/test.exs
config :my_app, :support_model, "fake:chat"
```

Without a script, `"fake:chat"` answers every call with an empty message,
which is enough for tests that don't depend on the answer. To script a test,
build the model with `BeamWeaver.Models.init_chat_model!/2` in `setup`, store
it with `Application.put_env/3`, and restore `"fake:chat"` in `on_exit/1`.
The environment is global, so such a test module must use `async: false`.

## Replay provider responses

To test the requests your application sends to a real provider, give a
provider model the replay transport. It answers from a cassette, a YAML file
of requests and their recorded responses, and never opens a connection:

<!-- snippet: run -->
```elixir
cassette = """
requests:
- method: POST
  uri: https://api.openai.com/v1/responses
  body: '{"model": "gpt-5.4-mini", "stream": false, "input": [{"type": "message", "role": "user", "content": "Where is my order A-1001?"}]}'
responses:
- status: {code: 200, message: OK}
  headers: {content-type: [application/json]}
  body:
    string: '{"status": "completed", "output": [{"type": "message", "role": "assistant", "content": [{"type": "output_text", "text": "Order A-1001 shipped on Monday."}]}]}'
"""

path = Path.join(System.tmp_dir!(), "order_status.yml")
File.write!(path, cassette)

{:ok, model} =
  BeamWeaver.Models.init_chat_model("openai:gpt-5.4-mini",
    api_key: "test-key",
    transport: BeamWeaver.Transport.Replay,
    transport_opts: [cassette_path: path]
  )

{:ok, reply} = BeamWeaver.Core.ChatModel.invoke(model, "Where is my order A-1001?")
Message.text(reply)
#=> "Order A-1001 shipped on Monday."
```

In your project, keep cassettes in a directory such as `test/cassettes/`. A
request matches an interaction when its method, URL and JSON body match. The
body is compared as JSON, so key order and spacing don't matter, a `uri` of
`'**REDACTED**'` matches any URL, and headers are not compared, so cassettes
hold no API key. Cassettes may be gzipped (`.yml.gz`).

A request that matches nothing fails with a `:transport_error` whose
`details.reason` is `:cassette_mismatch`; `details.request` shows the request
and `details.expected` the ones the cassette holds:

```elixir
BeamWeaver.Core.ChatModel.invoke(model, "Where is my order A-1002?")
#=> {:error, %BeamWeaver.Core.Error{type: :transport_error, details: %{reason: :cassette_mismatch}}}
```

BeamWeaver has no recorder, so that is how you write a cassette: put in the
response you expect, run the test, and copy the request body from
`details.request`.
An agent needs one interaction per model call. To build responses in code,
write your own transport, as on the [TypeSafe](providers/typesafe.md#testing)
page.

## Reference

- [`BeamWeaver.Models.FakeChatModel`](https://hexdocs.pm/beam_weaver/BeamWeaver.Models.FakeChatModel.html): the scripted chat model
- [`BeamWeaver.Models.FakeEmbeddingModel`](https://hexdocs.pm/beam_weaver/BeamWeaver.Models.FakeEmbeddingModel.html): deterministic embeddings
- [`BeamWeaver.Agent.Middleware.ToolEmulator`](https://hexdocs.pm/beam_weaver/BeamWeaver.Agent.Middleware.ToolEmulator.html): answers tool calls with a model
- [`BeamWeaver.Core.Tool`](https://hexdocs.pm/beam_weaver/BeamWeaver.Core.Tool.html): `invoke/3` runs a tool without a model
- [`BeamWeaver.Transport.Replay`](https://hexdocs.pm/beam_weaver/BeamWeaver.Transport.Replay.html): answers provider requests from a cassette
- [`BeamWeaver.Transport`](https://hexdocs.pm/beam_weaver/BeamWeaver.Transport.html): the behaviour for your own transports
