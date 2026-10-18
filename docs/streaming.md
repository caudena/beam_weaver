# Streaming

`stream_events/2` reports a run while it happens: the model's text as it is
written, tool calls as they start and finish, state updates, and progress
events of your own. Use it to show an answer word by word in a UI or a
terminal, or to tell people what an agent is doing.

## Stream an answer

Give the model `stream: true`, then call `stream_events/2` with `live: true`:

```elixir
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
    stream: true,
    responses: [
      FakeChatModel.tool_call("lookup_order", %{"order_id" => "A-1001"}),
      "Your order A-1001 shipped on Monday. Tracking went to ada@example.com."
    ]

  system_prompt "You are Acme's support agent. Look orders up before you answer."
  tools [MyApp.Tools.LookupOrder]
end

alias BeamWeaver.Stream.Events

{:ok, events} =
  MyApp.SupportAgent.stream_events(%{messages: ["Where is my order A-1001?"]}, live: true)

for %{event: %Events.Token{text: text}} <- events, do: text
#=> ["Your ", "order ", "A-1001 ", "shipped ", "on ", "Monday. " | _]
```

Each item in `events` is an envelope, and its `event` field holds a typed
event. `Token` events carry the model's text a piece at a time: the fake
model sends a word per token, real providers a few characters. In a terminal,
`IO.write(text)` each one as it arrives.

`stream: true` asks the model to stream. Without it the answer still arrives,
but in one piece. Provider models take the same option:
`model "anthropic:claude-haiku-4-5", stream: true`.

## Events

`events` is an `Enumerable` of `%BeamWeaver.Stream.Envelope{}` structs. The
envelope says where an event came from (`node`, `namespace`, `step`,
`run_id`), and its `event` is one of the structs in `BeamWeaver.Stream.Events`:

| Event | Fields | Sent when |
|---|---|---|
| `Token` | `text` | the model writes a piece of text |
| `MessageChunk` | `chunk` | the same piece as a message chunk, plus reasoning or tool-call pieces when the provider sends them |
| `Message` | `message` | a whole message joins the conversation |
| `ToolStart` | `tool_call_id`, `tool_name`, `input` | a tool starts |
| `ToolDelta` | `tool_call_id`, `delta` | a running tool reports progress |
| `ToolFinish` | `tool_call_id`, `output` | a tool returns |
| `ToolError` | `tool_call_id`, `message`, `error_type` | a tool fails; the model sees the error and goes on |
| `GraphUpdate` | `update` | a step ends; the changes are keyed by node name |
| `GraphValue` | `value` | a step ends; this is the whole state |
| `Custom` | `payload` | your code emits an event |
| `Done` | `usage` | a streamed model call ends (`stream: true`) |
| `Error` | `error` | the run fails; nothing follows it |
| `Debug` | `payload` | the stream starts or stops, the run pauses, or a model call fails |

`Task` events report each node's start and finish (both arrive once the node
is done), and `Checkpoint` events the state after each step. Match on the
events you need and skip the rest. This builds a progress log from the tool
events:

```elixir
Enum.flat_map(events, fn
  %{event: %Events.ToolStart{tool_name: name, input: input}} -> ["calling #{name} with #{inspect(input)}"]
  %{event: %Events.ToolFinish{output: output}} -> ["got: #{output}"]
  _other -> []
end)
#=> ["calling lookup_order with %{\"order_id\" => \"A-1001\"}", "got: Order A-1001 shipped on Monday."]
```

Several tool calls in one turn run at the same time, so their events can
interleave; use `tool_call_id` to tell them apart.

`BeamWeaver.Stream.event_mode/1` sorts events into channels: `:messages`
(text and messages), `:tools`, `:updates`, `:values`, `:custom`, `:tasks`,
`:checkpoints`, `:lifecycle` and `:debug` (which also holds `Done` and
`Error`). Use it to keep one kind of event:

```elixir
events
|> Enum.filter(&(BeamWeaver.Stream.event_mode(&1.event) == :tools))
|> length()
#=> 2
```

To have the run send only some kinds of events, pass their channels as
`stream_mode:`. The others are never sent, which saves copying the whole
state to your process at every step when you only show text:

```elixir
{:ok, chosen} =
  MyApp.SupportAgent.stream_events(%{messages: ["Where is my order A-1001?"]},
    live: true,
    stream_mode: [:messages, :tools]
  )

chosen |> Enum.map(&BeamWeaver.Stream.event_mode(&1.event)) |> Enum.uniq()
#=> [:messages, :tools]
```

The default, `:events`, sends every event. `:debug` also selects `Task` and
`Checkpoint` events, and a run that fails still ends with its `Error` event.

## Live streams

With `live: true`, `stream_events/2` returns at once and the agent runs while
you read the events. The stream is lazy:

- The run starts when you start reading it, and every pass over `events`
  starts a new run. Use `Enum.to_list/1` once if you need the events twice.
- If you stop reading early, for example with `Enum.find/2`, BeamWeaver
  cancels the run.
- The run belongs to the process that reads the stream and stops if that
  process exits.

```elixir
first_call = Enum.find(events, &match?(%{event: %Events.ToolStart{}}, &1))
first_call.event.input
#=> %{"order_id" => "A-1001"}
```

Without `live: true`, `stream_events/2` runs to the end and then returns the
same events, in the same order, as a list. Use it when nothing needs the
events while the run works, such as in tests and batch jobs:

```elixir
{:ok, collected} = MyApp.SupportAgent.stream_events(%{messages: ["Where is my order A-1001?"]})

for %{event: %Events.ToolFinish{output: output}} <- collected, do: output
#=> ["Order A-1001 shipped on Monday."]
```

A run that pauses returns `{:interrupted, interrupt}` instead, with its events
in `interrupt.events`, and a run that fails returns `{:error, error}`.

## The final answer

`Message` events carry whole messages, so the last assistant message is the
answer:

```elixir
Enum.reduce(events, nil, fn
  %{event: %Events.Message{message: %{role: :assistant} = message}}, _answer ->
    BeamWeaver.Core.Message.text(message)

  _event, answer ->
    answer
end)
#=> "Your order A-1001 shipped on Monday. Tracking went to ada@example.com."
```

Show `Token` text while the run is going and treat the `Message` as the
finished copy; don't append its text again. If you only need the answer and
not the progress, `invoke/2` is simpler.

## Redact a stream

Events are plain data, so you can change them with `Stream.map/2` and
`Stream.filter/2` before they leave your application. This masks order ids
token by token:

```elixir
events
|> Stream.filter(&match?(%{event: %Events.Token{}}, &1))
|> Enum.map_join(fn %{event: token} -> String.replace(token.text, ~r/A-\d+/, "[order]") end)
#=> "Your order [order] shipped on Monday. Tracking went to ada@example.com."
```

A value can be split across two tokens, and a rule that looks at one token at
a time misses it. `BeamWeaver.Agent.Middleware.PII.stream_transform/1` holds
back the most recent text until the model's reply ends, so it can redact
values that span tokens:

```elixir
{redact, pending} = BeamWeaver.Agent.Middleware.PII.stream_transform(type: :email, strategy: :redact)

safe_events =
  events
  |> Stream.transform(pending, fn envelope, pending ->
    {{:ok, out}, pending} = redact.(envelope, pending)
    {List.wrap(out), pending}
  end)
  |> Enum.to_list()

for %{event: %Events.Token{text: text}} <- safe_events, into: "", do: text
#=> "Your order A-1001 shipped on Monday. Tracking went to [REDACTED_EMAIL]."
```

`Token` and `MessageChunk` events carry the same text, and the transform holds
each back separately, so the whole stream can go through it. The message
chunks come out redacted too:

```elixir
for %{event: %Events.MessageChunk{chunk: chunk}} <- safe_events, into: "", do: chunk.content
#=> "Your order A-1001 shipped on Monday. Tracking went to [REDACTED_EMAIL]."
```

The transform also edits the reasoning and tool-call arguments a model
streams, a whole `Message`, tool events and state snapshots (`GraphValue`).
Use it even when the agent has PII middleware: the middleware edits the text
of the saved message once the model finishes, but tokens go out while the
model writes, and the middleware leaves tool-call arguments and reasoning as
they are. See [Guardrails](guardrails.md#redact-personal-data).

## Errors

A run that fails doesn't raise in the middle of your loop. The stream ends
with an `Error` event that holds the reason. Here a fake model that always
fails stands in for a provider outage:

```elixir
defmodule MyApp.OfflineAgent do
  use BeamWeaver.Agent

  model "fake:chat",
    stream: true,
    error: BeamWeaver.Core.Error.new(:provider_error, "upstream timed out")
end

{:ok, events} = MyApp.OfflineAgent.stream_events(%{messages: ["Where is my order A-1001?"]}, live: true)

events |> Enum.to_list() |> List.last()
#=> %{event: %Events.Error{error: %BeamWeaver.Core.Error{type: :provider_error}}}
```

Without `live: true` the same run returns the error:

```elixir
MyApp.OfflineAgent.stream_events(%{messages: ["Where is my order A-1001?"]})
#=> {:error, %BeamWeaver.Core.Error{type: :provider_error}}
```

A provider can also fail partway through a reply, after some of it has
streamed: Anthropic, for example, ends the stream with an `overloaded_error`
event. The model call then fails with the error the same failure gets without
streaming, so `ModelRetry` retries an overload, a rate limit or a server
error, but not a content filter, an invalid request, a context overflow or an
exhausted quota (see [Built-in Middleware](builtin_middleware.md)).

A model call that fails sends a `Debug` event whose payload is
`%{type: :model_call_failed, error: error}` (in the `:debug` channel, like
`Done`). The tokens the call sent stay in the stream, but they are not part of
the answer, and the cut-off reply is not saved. When middleware such as
`ModelRetry` or `ModelFallback` calls a model again, its tokens follow and the
run goes on: only a run that fails ends with an `Error` event. Here the
agent's model is down and a fallback model answers:

```elixir
defmodule MyApp.ResilientAgent do
  use BeamWeaver.Agent

  alias BeamWeaver.Agent.Middleware

  model "fake:chat",
    stream: true,
    error: BeamWeaver.Core.Error.new(:provider_error, "upstream timed out")

  middleware [
    {Middleware.ModelFallback,
     fallbacks: [BeamWeaver.Models.init_chat_model!("fake:chat", stream: true, responses: ["Your order shipped on Monday."])]}
  ]
end

{:ok, events} = MyApp.ResilientAgent.stream_events(%{messages: ["Where is my order A-1001?"]}, live: true)

Enum.flat_map(events, fn
  %{event: %Events.Debug{payload: %{type: :model_call_failed, error: error}}} -> [{:failed, error.type}]
  %{event: %Events.Token{text: text}} -> [text]
  %{event: %Events.Error{}} -> [:run_failed]
  _other -> []
end)
#=> [{:failed, :provider_error}, "Your ", "order ", "shipped ", "on ", "Monday."]
```

Tool failures are different: they arrive as `ToolError` events, the model
reads the error, and the run goes on. When the call itself is invalid, for
example when an agent that needs a checkpointer has none, `stream_events/2`
returns `{:error, error}` before anything runs.

## Tool progress and custom events

A tool can report progress while it works. Inject the tool runtime and call
`BeamWeaver.Core.ToolRuntime.emit_output_delta/2`; each call becomes a
`ToolDelta` event. Add such a tool to the agent:

```elixir
defmodule MyApp.Tools.SearchHelpCenter do
  use BeamWeaver.Tool

  name "search_help_center"
  description "Search Acme's help center for articles about a topic."

  schema do
    field :query, :string, description: "What to search for"
  end

  injected :tool_runtime, :tool_runtime

  @impl true
  def invoke(_tool, %{"query" => query} = input, _opts) do
    BeamWeaver.Core.ToolRuntime.emit_output_delta(input.tool_runtime, "Searching for #{query}...")
    {:ok, "Refunds reach your card within 5 business days."}
  end
end

defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  alias BeamWeaver.Models.FakeChatModel

  model "fake:chat",
    stream: true,
    responses: [
      FakeChatModel.tool_call("search_help_center", %{"query" => "refund timing"}),
      "Refunds reach your card within 5 business days."
    ]

  tools [MyApp.Tools.LookupOrder, MyApp.Tools.SearchHelpCenter]
end

{:ok, events} = MyApp.SupportAgent.stream_events(%{messages: ["How long do refunds take?"]}, live: true)

for %{event: %Events.ToolDelta{delta: delta}} <- events, do: delta
#=> ["Searching for refund timing..."]
```

A real search tool would query a vector store; see
[Retrieval](retrieval.md#agentic-retrieval).

For anything else, emit your own events. A graph node that takes a second
argument gets the run's `BeamWeaver.Graph.Runtime`, and every value you pass
to its `stream_writer` arrives as a `Custom` event:

```elixir
defmodule MyApp.TicketTriage do
  use BeamWeaver.Graph

  alias BeamWeaver.Graph

  def graph do
    Graph.new()
    |> Graph.add_node(:classify, &classify/2)
    |> Graph.add_edge(Graph.start(), :classify)
    |> Graph.add_edge(:classify, Graph.end_node())
  end

  def classify(%{subject: subject}, runtime) do
    runtime.stream_writer.(%{stage: "classifying", subject: subject})
    %{category: if(subject =~ ~r/refund/i, do: :billing, else: :general)}
  end
end

{:ok, events} = MyApp.TicketTriage.stream_events(%{subject: "Refund for A-1001"}, live: true)

for %{event: %Events.Custom{payload: payload}} <- events, do: payload
#=> [%{stage: "classifying", subject: "Refund for A-1001"}]
```

A tool can do the same: declare `injected :runtime, :runtime` and call
`input.runtime.stream_writer.(payload)`. Middleware state hooks get the same
runtime as their last argument, and wrap hooks find it in `request.runtime`.

## Tool-call arguments

Some providers stream a tool call's arguments in pieces, inside
`MessageChunk` events (`chunk.tool_call_chunks`). Read the pieces to show a
call while the model forms it, and merge the chunks with
`BeamWeaver.Stream.Finalize.finalize/1` to get the finished call. Here two
hand-made chunks stand in for a provider stream:

```elixir
alias BeamWeaver.Core.Messages

chunks = [
  Messages.ai_chunk("",
    tool_call_chunks: [Messages.tool_call_chunk(id: "call_1", index: 0, name: "lookup_order", args: ~s({"order_id))]
  ),
  Messages.ai_chunk("", tool_call_chunks: [Messages.tool_call_chunk(id: "call_1", index: 0, args: ~s(": "A-1001"}))])
]

[call] = BeamWeaver.Stream.Finalize.finalize(chunks).tool_calls
{call.name, call.args}
#=> {"lookup_order", %{"order_id" => "A-1001"}}
```

From a live stream, collect the chunks with
`for %{event: %Events.MessageChunk{chunk: chunk}} <- events, do: chunk`. An
agent merges them itself: the finished call is on the `Message` event that
follows.

## When the run pauses

If the run stops for human review, the live stream sends a `Debug` event
whose payload is `%{type: :interrupt, interrupt: interrupt}`, and then the
stream ends. Without `live: true`, `stream_events/2` returns
`{:interrupted, interrupt}`, with the events in `interrupt.events`.
Pass that `interrupt` to the review helpers and resume the run as shown in
[Human-in-the-Loop](human_in_the_loop.md). When the node described the answer
it expects, `interrupt.response_schema` holds it as JSON schema, for your app
to build its form from; see
[Check the answer](human_in_the_loop.md#check-the-answer).

## Subgraphs

The events of a [subgraph](subgraphs.md) arrive in its parent's stream, with
the path of node names that leads to it as their `namespace`, such as
`["refund_check"]`; the run's own events have `namespace: []`. A subgraph that
fails sends no `Error` event, since only a run that fails ends with one, at the
top level. The node that ran the subgraph fails instead: its `Task` event, in
the parent's namespace, has `kind: :error` and the error as its `payload`, and
the run fails with that error unless the node's `retry:` or `error_handler:`
recovers. A collected stream of a failed run returns only the error, so read a
live one to see its events:

```elixir
alias BeamWeaver.Graph

refund_check =
  Graph.new(name: "RefundCheck")
  |> Graph.add_node(:check_amount, fn %{amount: amount} ->
    if amount > 0, do: %{refund_ok: amount <= 100}, else: {:error, "the amount must be positive"}
  end)
  |> Graph.add_edge(Graph.start(), :check_amount)
  |> Graph.add_edge(:check_amount, Graph.end_node())
  |> Graph.compile!()

triage =
  Graph.new()
  |> Graph.add_node(:refund_check, refund_check)
  |> Graph.add_edge(Graph.start(), :refund_check)
  |> Graph.add_edge(:refund_check, Graph.end_node())
  |> Graph.compile!()

{:ok, events} = Graph.Compiled.stream_events(triage, %{amount: -5}, live: true)
events = Enum.to_list(events)

for %{event: %Events.Error{}, namespace: namespace} <- events, do: namespace
#=> [[]]
```

`BeamWeaver.Stream.Subgraphs.from_events/2` sums up each subgraph run in a
stream. Its `status` is how the subgraph's node ended: `:completed`, `:failed`
with the error's message, or `:interrupted` when it paused. A subgraph that the
node's `retry:` ran again until it succeeded is `:completed`. Here the node
failed:

```elixir
for run <- BeamWeaver.Stream.Subgraphs.from_events(events), do: {run.path, run.status, run.error}
#=> [{["refund_check"], :failed, "the amount must be positive"}]
```

`BeamWeaver.Stream.Lifecycle.from_events/2` turns the same summaries into
`Lifecycle` events in each subgraph's namespace: `:started`, then its status.
Both read the `Task` events, which the default stream mode and the `:tasks` and
`:debug` modes include.

## Push tokens to a LiveView

Read the stream in its own process and send each token to the process that
shows it. A Phoenix LiveView stays responsive this way, and because the task
is linked to it, the run stops when the user leaves:

```elixir
defmodule MyApp.ChatStream do
  alias BeamWeaver.Stream.Events

  # Sends {:token, text} messages to `pid`, :retry when a model call fails
  # (the text it sent is not part of the answer), then :done or
  # {:error, error}.
  def start(question, pid) do
    Task.start_link(fn ->
      {:ok, events} = MyApp.SupportAgent.stream_events(%{messages: [question]}, live: true)

      Enum.each(events, fn
        %{event: %Events.Token{text: text}} -> send(pid, {:token, text})
        %{event: %Events.Debug{payload: %{type: :model_call_failed}}} -> send(pid, :retry)
        %{event: %Events.Error{error: error}} -> send(pid, {:error, error})
        _other -> :ok
      end)

      send(pid, :done)
    end)
  end

  # In the LiveView:
  #
  #     def handle_event("ask", %{"question" => question}, socket) do
  #       {:ok, _pid} = MyApp.ChatStream.start(question, self())
  #       {:noreply, assign(socket, answer: "")}
  #     end
  #
  #     def handle_info({:token, text}, socket),
  #       do: {:noreply, update(socket, :answer, &(&1 <> text))}
  #
  #     def handle_info(:retry, socket), do: {:noreply, assign(socket, answer: "")}
end

{:ok, _pid} = MyApp.ChatStream.start("How long do refunds take?", self())

receive do
  {:token, text} -> text
after
  1_000 -> :timeout
end
#=> "Refunds "
```

Send only what the page needs, such as tokens and errors, and leave the rest
of the events on the server.

## Reference

- [`BeamWeaver.Agent`](https://hexdocs.pm/beam_weaver/BeamWeaver.Agent.html): `stream_events/3` for agents
- [`BeamWeaver.Graph`](https://hexdocs.pm/beam_weaver/BeamWeaver.Graph.html): graph modules, whose `stream_events/2` takes the same options
- [`BeamWeaver.Stream`](https://hexdocs.pm/beam_weaver/BeamWeaver.Stream.html): `event_mode/1` and stream helpers
- [`BeamWeaver.Stream.Envelope`](https://hexdocs.pm/beam_weaver/BeamWeaver.Stream.Envelope.html): the wrapper around every event
- [`BeamWeaver.Stream.Events`](https://hexdocs.pm/beam_weaver/BeamWeaver.Stream.Events.html): the event structs
- [`BeamWeaver.Stream.Finalize`](https://hexdocs.pm/beam_weaver/BeamWeaver.Stream.Finalize.html): merges message chunks into a message
- [`BeamWeaver.Core.ToolRuntime`](https://hexdocs.pm/beam_weaver/BeamWeaver.Core.ToolRuntime.html): `emit_output_delta/2` for tool progress
- [`BeamWeaver.Graph.Runtime`](https://hexdocs.pm/beam_weaver/BeamWeaver.Graph.Runtime.html): the runtime with `stream_writer`
- [`BeamWeaver.Agent.Middleware.PII`](https://hexdocs.pm/beam_weaver/BeamWeaver.Agent.Middleware.PII.html): `stream_transform/1` for redacting streams
