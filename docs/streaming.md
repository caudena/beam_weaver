# Streaming

Streaming lets your application show progress while an agent works: text,
tool activity, state changes and your own events. It also changes ownership:
the process consuming a live stream owns the run.

Complete [Installation](installation.md). Run these blocks in order in IEx.

## Stream an answer

This real OpenAI call uses a local policy tool that emits a progress event:

```elixir
defmodule MyApp.PolicySearch do
  use BeamWeaver.Tool

  name "policy_search"
  description "Read the refund timing policy."
  injected :runtime, :tool_runtime

  schema do
    field :query, :string
  end

  @impl true
  def invoke(_tool, %{runtime: runtime}, _opts) do
    BeamWeaver.Core.ToolRuntime.emit_output_delta(runtime, "Reading the refund policy")
    {:ok, "Refunds take five business days."}
  end
end

defmodule MyApp.StreamingAgent do
  use BeamWeaver.Agent

  model "openai:gpt-5.4-mini", stream: true, max_tokens: 256, timeout: 60_000
  system_prompt "Call policy_search for refund questions, then explain its result."
  tools [MyApp.PolicySearch]
end

alias BeamWeaver.Stream.Events
{:ok, stream} = MyApp.StreamingAgent.stream_events(%{messages: ["How long do refunds take?"]}, live: true)
events = Enum.to_list(stream)
false = Enum.any?(events, &match?(%{event: %Events.Error{}}, &1))

%{event: %{tool_call_id: call_id}} =
  Enum.find(events, &match?(%{event: %Events.ToolStart{tool_name: "policy_search"}}, &1))

true = Enum.any?(events, &match?(%{event: %Events.ToolFinish{tool_call_id: ^call_id}}, &1))
true = Enum.any?(events, &match?(%{event: %Events.ToolDelta{}}, &1))
text = for %{event: %Events.Token{text: text}} <- events, into: "", do: text
true = byte_size(text) > 0
IO.puts(text)
```

Use `Enum.each/2` and `IO.write/1` on token events to display text as it arrives.
This example collects once so subsequent inspections do not repeat the run.
Token boundaries vary by provider; a token event need not contain a whole word.

## Live streams

Two options control different things: `stream: true` requests incremental
model output; `live: true` returns an enumerable that runs while you consume it.
Without model streaming, the agent can still report tools and state changes,
but model text arrives as a whole reply.

A live stream is lazy. Each enumeration starts a run. Enumerating it twice
can make two sets of API calls and repeat tool side effects. If you need
several views, materialize it once or dispatch events from a single consumer.
Stopping enumeration early cancels the run; so does the consumer process
exiting. Cancellation cannot undo an external side effect already performed.

Without `live: true`, the call runs to completion and returns a collected
list. An interrupted collected run returns `{:interrupted, interrupt}` with
`interrupt.events`; failure returns `{:error, error}`.

## Events

Each item is a `BeamWeaver.Stream.Envelope` with an `event`, `run_id`, `node`,
`namespace` and `step`. Use identifiers to correlate concurrent work.

| Event | Purpose |
| --- | --- |
| `Token` | Incremental model text in `text` |
| `MessageChunk` | Text, reasoning or partial tool-call data in `chunk` |
| `Message` | A completed message in `message` |
| `ToolStart`, `ToolDelta`, `ToolFinish`, `ToolError` | Tool lifecycle and progress, correlated by `tool_call_id` |
| `GraphUpdate`, `GraphValue` | Per-node updates or state values |
| `Custom` | Application-defined `payload` |
| `Task`, `Checkpoint` | Graph execution and persistence events |
| `Done` | A streamed **model call** ended; an agent can make another call |
| `Debug` | Lifecycle information, model-call failure or an interrupt |
| `Error` | The entire run failed |

`BeamWeaver.Stream.event_mode/1` classifies events. `stream_mode:` limits
emission to channels such as `:messages`, `:tools`, `:updates`, `:values`,
`:custom`, `:tasks`, `:checkpoints`, `:lifecycle` and `:debug`.
The default `:events` includes all channels. Terminal failures remain visible
when filtering. Restrict channels when you do not need full state snapshots.

Filter the already-collected events from the first example without starting another run:

```elixir
tool_events = Enum.filter(events, &(BeamWeaver.Stream.event_mode(&1.event) == :tools))
true = Enum.any?(tool_events, &match?(%{event: %Events.ToolStart{}}, &1))
true = Enum.any?(tool_events, &match?(%{event: %Events.ToolFinish{}}, &1))
IO.inspect(Enum.map(tool_events, & &1.event.__struct__), label: "Tool event types")
```

## The final answer

Use tokens for provisional UI text and completed messages as the authoritative
copy. Do not append a complete message after already displaying its tokens.

```elixir
answers =
  for %{event: %Events.Message{message: %{role: :assistant} = message}} <- events,
      message.tool_calls in [nil, []],
      do: BeamWeaver.Core.Message.text(message)

answer = List.last(answers)
true = is_binary(answer) and byte_size(answer) > 0
```

End of enumeration means the stream ended; inspect terminal errors and
interrupts before treating that as successful completion. A `Done` event
belongs to a model call, not necessarily the whole agent run.

## Errors

A live run can fail after `stream_events/2` returned successfully. Handle
`Events.Error` inside the consumer. Invalid setup can instead return an error
before a stream is created.

A failed model attempt emits a debug payload with `type: :model_call_failed`.
Retry or fallback middleware can then start another attempt. Already emitted
tokens from the failed attempt are provisional and must not be presented as
part of the final answer. Clear or replace that attempt's UI text. A tool
failure is different: `ToolError` normally goes back to the model for recovery.

[Built-in Middleware](builtin_middleware.md) describes retry policies.
[Testing](testing.md) shows how to reproduce failure paths deterministically.

## Tool progress and custom events

The tool above uses `BeamWeaver.Core.ToolRuntime.emit_output_delta/2`.
For arbitrary progress payloads, a graph node's second argument is a runtime
whose `stream_writer` emits custom events:

```elixir
defmodule MyApp.ProgressGraph do
  use BeamWeaver.Graph

  graph do
    node :classify, &__MODULE__.classify/2
    edge start(), :classify
    edge :classify, finish()
  end

  def classify(_state, runtime) do
    runtime.stream_writer.(%{stage: "classifying"})
    %{category: "billing"}
  end
end

{:ok, stream} = MyApp.ProgressGraph.stream_events(%{}, live: true)
progress = for %{event: %Events.Custom{payload: payload}} <- stream, do: payload
[%{stage: "classifying"}] = progress
```

Tools can inject `:runtime` for the same writer. Middleware state hooks receive
it directly; wrapper hooks read `request.runtime`.

## Tool-call arguments

`MessageChunk` can contain partial JSON arguments in `tool_call_chunks`.
They are display data until complete; never execute an action from a partial
argument string. Agents assemble the call for you. Direct model consumers
can use `BeamWeaver.Stream.Finalize.finalize/1` to merge chunks into a message.
Use call IDs and indices to keep simultaneous calls separate.

Tool arguments can span arbitrary chunk boundaries. Assemble them before parsing/executing:

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

## When the run pauses

A live interrupt arrives as a debug payload with `type: :interrupt` and an
`interrupt` value, then the stream ends. Display its review request and resume
using the original thread/checkpointer plus fresh caller context. When
provided, `interrupt.response_schema` describes the expected form data.
See [Human Review](human_in_the_loop.md).

## Redact a stream

A sensitive value can span tokens. Replacing text inside each token separately
can leak it. `BeamWeaver.Agent.Middleware.PII.stream_transform/1` buffers text
until it can apply the configured policy and also transforms message chunks,
whole messages, tool data and state snapshots.

Apply the transform before events leave your server. PII middleware on saved
messages alone does not protect already-emitted tokens. [Guardrails](guardrails.md)
explains the distinction and redaction strategies.

The transform buffers text across chunk boundaries. Supply a synthetic email in two chunks to see that boundary handled:

```elixir
alias BeamWeaver.Stream.{Envelope, Events}
{transform, pending} = BeamWeaver.Agent.Middleware.PII.stream_transform(type: :email, strategy: :redact)

source = [
  %Envelope{event: %Events.Token{text: "Contact ada@"}},
  %Envelope{event: %Events.Token{text: "example.com for help."}},
  %Envelope{event: %Events.Done{}}
]

safe =
  source
  |> Stream.transform(pending, fn envelope, acc ->
    {{:ok, emitted}, acc} = transform.(envelope, acc)
    {List.wrap(emitted), acc}
  end)
  |> Enum.to_list()

text = for %{event: %Events.Token{text: part}} <- safe, into: "", do: part
false = text =~ "ada@example.com"
true = text =~ "[REDACTED_EMAIL]"
```

## Subgraphs

Subgraph events retain the path of node names in `namespace`. Parent events
use `[]`. A subgraph failure is first a node failure; retry or an error handler
may recover it. Only an unrecovered top-level failure ends with `Error`.

`BeamWeaver.Stream.Subgraphs.from_events/2` summarizes paths and statuses.
`BeamWeaver.Stream.Lifecycle.from_events/2` produces lifecycle events from
those summaries. Keep `Task` events when using either helper.

## Push tokens to a LiveView

Consume the stream in a supervised task rather than in the LiveView callback.
Send only UI events to the LiveView: provisional text, completed messages,
review requests and failures. Correlate messages with a run ID so events from
an older request cannot overwrite a newer answer.

Tie task cancellation explicitly to your application's lifecycle. A normal
process exit does not automatically terminate every linked process. Cancel
work when the view disconnects if it belongs to that view; use a persistent
job owner when it must continue. Keep final state in a checkpointer rather
than only in a socket assignment.

This complete bridge uses a supervised task and monitors the receiving process. A LiveView can handle the tagged messages in `handle_info/2`; on disconnect, the monitor stops the worker. Only one process enumerates the stream:

```elixir
defmodule MyApp.ChatStream do
  def start(supervisor, receiver, question) do
    owner = make_ref()

    {:ok, worker} =
      Task.Supervisor.start_child(supervisor, fn ->
        receiver_ref = Process.monitor(receiver)

        task =
          Task.Supervisor.async_nolink(supervisor, fn ->
            case MyApp.StreamingAgent.stream_events(%{messages: [question]}, live: true) do
              {:ok, stream} ->
                Enum.each(stream, &send(receiver, {:agent_event, owner, &1}))
                :stream_ended

              other ->
                other
            end
          end)

        receive do
          {ref, result} when ref == task.ref ->
            Process.demonitor(ref, [:flush])
            Process.demonitor(receiver_ref, [:flush])
            send(receiver, {:agent_stream_finished, owner, result})

          {:DOWN, ^receiver_ref, :process, ^receiver, _} ->
            Task.shutdown(task, :brutal_kill)

          {:DOWN, ref, :process, _pid, reason} when ref == task.ref ->
            send(receiver, {:agent_stream_finished, owner, {:error, reason}})
        end
      end)

    {:ok, worker, owner}
  end
end

{:ok, supervisor} = Task.Supervisor.start_link()

try do
  {:ok, _worker, run_ref} = MyApp.ChatStream.start(supervisor, self(), "How long do refunds take?")

  receive do
    {:agent_stream_finished, ^run_ref, :stream_ended} -> :ok
    {:agent_stream_finished, ^run_ref, other} -> raise inspect(other)
  after
    120_000 -> raise "Stream did not finish"
  end

  receive do
    {:agent_event, ^run_ref, %{event: %BeamWeaver.Stream.Events.ToolFinish{}}} -> :ok
  after
    0 -> raise "No tool completion was delivered"
  end
after
  Supervisor.stop(supervisor)
end
```

## Custom producers and backpressure

`BeamWeaver.Stream.Mux` combines caller-owned producers through a bounded queue.
A `Stream.Sink` lets a producer emit and check cancellation; child sinks attach
nested namespaces. `Stream.Policy` chooses blocking, drop-newest, drop-oldest
or error behavior on overflow. Size the buffer and emission timeout for the
consumer; dropping events can make an otherwise complete run impossible to
reconstruct from its stream.

Heartbeats are opt-in progress signals, not evidence that a model/tool finished.
Read-side `MessagesTransformer`, `Transformers` and lifecycle/subgraph helpers
project collected events without starting work. A synthesized message from
partial deltas is not a substitute for a completed provider outcome.

Producer forms select the callback argument:

| Entry | Callback receives |
| --- | --- |
| `fn emit -> ... end` | A one-argument emission function |
| `{name, function}` | An emission function, with a named producer |
| `{:sink, name, function}` | A `Stream.Sink` for child namespaces and cancellation checks |

`max_buffer:` defaults to 256 items, `emit_timeout:` to 5,000 ms, and the
whole-stream `timeout:` to infinity. Choose explicit budgets for application
work. Two producers can share a bounded stream while retaining separate
namespaces. All events below are consumed once:

```elixir
alias BeamWeaver.Stream.{Mux, Sink, Events}

producers =
  for name <- ["orders", "policy"] do
    {:sink, name,
     fn sink ->
       child = Sink.child(sink, namespace: [name])
       :ok = Sink.emit(child, %Events.Custom{payload: %{source: name, status: "ready"}})
     end}
  end

items = Mux.stream(producers, max_buffer: 4, overflow: :block, timeout: 5_000) |> Enum.to_list()

ready =
  for %{event: %Events.Custom{payload: %{source: source}}, namespace: namespace} <- items,
      do: {source, namespace}

true = {"orders", ["orders"]} in ready
true = {"policy", ["policy"]} in ready
false = Enum.any?(items, &match?(%{event: %Events.Error{}}, &1))
```
