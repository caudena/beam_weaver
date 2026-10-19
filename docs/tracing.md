# Tracing

Traces connect agent runs, model requests, tool calls and delegated work.
Use them to answer what actually ran, where time/tokens went and why a task
failed. Local traces are useful during development; export is a separate
operation with its own delivery and retention lifecycle.

Complete [Installation](installation.md). The first example records a real
OpenAI request and checks the resulting model usage.

## Read a trace

```elixir
defmodule MyApp.TracedAgent do
  use BeamWeaver.Agent
  model "openai:gpt-5.4-mini", max_tokens: 128, timeout: 60_000
end

defmodule MyApp.TraceTree do
  def flatten(%{run: run, children: children}), do: [run | Enum.flat_map(children, &flatten/1)]
end

alias BeamWeaver.Tracing

{outcome, root_id} =
  Tracing.with_run("support-request", fn ->
    result =
      MyApp.TracedAgent.invoke(%{messages: ["Define parcel tracking briefly."]},
        trace: [name: "support_chat", user_id: "ada", thread_id: "ticket-42"]
      )

    {result, Tracing.capture_context().run_id}
  end)

{:ok, result} = outcome
true = byte_size(result.messages |> List.last() |> BeamWeaver.Core.Message.text()) > 0
{:ok, tree} = Tracing.get_tree(root_id)
runs = MyApp.TraceTree.flatten(tree)
model_runs = Enum.filter(runs, &(&1.kind == :model))
true = model_runs != []
true = Enum.all?(model_runs, &(&1.status == :ok and &1.usage.total_tokens > 0))
```

Runs contain inputs, outputs, usage, metadata, status, error and timestamps.
Nested graph tasks propagate trace context. A failed owner's exit finalizes
unfinished trace records as failures rather than leaving them running forever.

## What gets traced

| Kind | Work |
| --- | --- |
| `:graph` | Agents, workflows and nested runs |
| `:model` | Provider requests, messages, usage and model identity |
| `:tool` | Model-supplied arguments and tool outcomes |
| `:chain` | Middleware hooks |
| Custom kinds | Application spans you create |

Local storage retains active runs and a bounded recent history. Default
retention is 10,000 records; `max_runs: 0` retains active work only.
Read needed trees before eviction. Local memory is not an audit database.
`Tracing.clear/0` removes local records and should not be used casually on a
node serving other callers.

## Name and tag a run

The `trace:` option supports name, user/session/thread IDs, execution mode,
environment/version, indexed flat `fields:` and additional `metadata:`.
Descendant model/tool runs inherit context. Use stable application identities
and avoid storing entire user objects as metadata.

Fields normalize values to strings and omit nested/secret-looking values.
Direct model calls accept `trace_metadata:` separately from provider options.
Profile prices can estimate cost; actual provider billing is a separate source.

## Leave a call out

`trace: false` on `BeamWeaver.Core.ChatModel.invoke/3` or
`BeamWeaver.Core.Tool.invoke/3` records no run for that call, for example a
health check. Runs the call starts itself, like a model call inside the
tool, are still recorded, under the caller's run.

```elixir
{:ok, model} = BeamWeaver.Models.init_chat_model("openai:gpt-5.4-mini", max_tokens: 64, timeout: 60_000)

{{:ok, _reply}, caller_id} =
  Tracing.with_run("health-check", fn ->
    reply = BeamWeaver.Core.ChatModel.invoke(model, "Reply with OK.", trace: false)
    {reply, Tracing.capture_context().run_id}
  end)

{:ok, %{children: []}} = Tracing.get_tree(caller_id)
```

An agent or graph run is always recorded. `trace: false` on
`BeamWeaver.Agent.invoke/3` or a graph's `invoke` turns nothing off; there
`trace:` only names and tags the run.

## Trace your own code

```elixir
{:ok, run} = Tracing.start_run("load_customer", kind: :tool, inputs: %{customer_id: "ada"})
{:ok, finished} = Tracing.finish_run(run, outputs: %{plan: "pro"})
:ok = finished.status
%{plan: "pro"} = finished.outputs
```

Use `with_run/3` for scoped code or explicit start/finish when integrating an
existing lifecycle. `Tracing.async/2` propagates context into tasks; a
`supervisor:` can assign task ownership. Ensure error and cancellation paths
finish or reconcile spans too.

## Redaction

Built-in redaction targets credential-looking keys and values, including
authorization headers, secret URL components and API-key patterns. Tool traces
record model-supplied arguments, not injected runtime state/store/context.

This is not comprehensive personal-data removal. Message text, artifacts and
custom fields can contain sensitive business data. Apply your data policy
before export and use [PII controls](guardrails.md#redact-personal-data) where
appropriate. Never log raw transport requests wholesale.

## Export to WeaveScope

Set these values in your application's runtime configuration before startup:

```elixir
import Config

config :beam_weaver, :weave_scope,
  endpoint: "https://app.weavescope.com",
  api_key: System.get_env("WEAVESCOPE_API_KEY"),
  otp_app: :my_app
```

Without a configured key, the built-in exporter does not send hosted traces.
The queue batches observations and retries failed delivery. Backpressure,
retry exhaustion and dead letters are observable:

```elixir
stats = BeamWeaver.Tracing.Exporters.WeaveScope.Queue.stats()
true = is_integer(stats.queued)
true = is_integer(stats.dead_letters)
```

The default overflow policy blocks producers when the buffer fills. That can
slow agent runs during an extended exporter outage. Drop policies trade
observability for availability. [Configuration](configuration.md#tracing)
lists queue limits, batch settings and shutdown budgets.

Flush before a short-lived script exits. During application shutdown the queue
has a bounded drain period, not an unlimited delivery guarantee. Monitor
backlog and dead letters rather than assuming configuration implies receipt.

## Verify export delivery locally

This complete one-request receiver binds only to loopback and closes its socket
after receiving an export. It uses the actual HTTP exporter and needs no hosted
account or repository support files:

```elixir
defmodule MyApp.TraceReceiver do
  # A one-request local fixture. It neither forwards nor persists payloads.
  def start(response \\ %{}) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :http_bin, ip: {127, 0, 0, 1}, reuseaddr: true])

    {:ok, {_address, port}} = :inet.sockname(listener)

    task =
      Task.async(fn ->
        try do
          {:ok, socket} = :gen_tcp.accept(listener, 10_000)

          try do
            {:ok, {:http_request, method, {:abs_path, path}, _version}} = :gen_tcp.recv(socket, 0, 10_000)
            headers = headers(socket, %{})
            :ok = :inet.setopts(socket, packet: :raw)
            size = String.to_integer(Map.fetch!(headers, "content-length"))
            {:ok, body} = :gen_tcp.recv(socket, size, 10_000)

            response = BeamWeaver.JSON.encode!(response)

            :ok =
              :gen_tcp.send(
                socket,
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{byte_size(response)}\r\nConnection: close\r\n\r\n" <>
                  response
              )

            %{method: method, path: path, headers: headers, body: BeamWeaver.JSON.decode!(body)}
          after
            :gen_tcp.close(socket)
          end
        after
          :gen_tcp.close(listener)
        end
      end)

    {"http://127.0.0.1:#{port}", task}
  end

  defp headers(socket, headers) do
    case :gen_tcp.recv(socket, 0, 10_000) do
      {:ok, :http_eoh} ->
        headers

      {:ok, {:http_header, _index, name, _reserved, value}} ->
        headers(socket, Map.put(headers, name |> to_string() |> String.downcase(), value))
    end
  end
end

{endpoint, receiver} = MyApp.TraceReceiver.start()
{:ok, run} = Tracing.start_run("local-export", exporter: nil)
{:ok, run} = Tracing.finish_run(run, outputs: %{answer: "Ready"})
:ok = BeamWeaver.Tracing.Exporters.WeaveScope.export(:ok, run, endpoint: endpoint, api_key: "local-receiver-fixture")
request = Task.await(receiver, 10_000)
:POST = request.method
"/api/v1/observations/batch" = request.path
[event] = request.body["events"]
true = event["observation_id"] == run.id
```

The receiver closes after the request. This checks serialization and delivery
locally; hosted authentication/project access depends on your configured
WeaveScope account. The receiver code above is only for this local delivery check.

## Your own exporter

Implement `Tracing.Exporter.export/3` for started/ok/error events. Exporters
receive redacted runs. A custom exporter replaces the built-in destination.
Callbacks execute in the emitting process; enqueue slow work elsewhere.
Owner-exit failures can be delivered from a different process. Exporter failure
must not be confused with the agent's own result.

Pass the exporter module in `exporter:` and its configuration in `exporter_opts:`. This example confirms completion delivery for a real model run:

```elixir
defmodule MyApp.TraceObserver do
  @behaviour BeamWeaver.Tracing.Exporter
  @impl true
  def export(event, run, opts) do
    send(Keyword.fetch!(opts, :receiver), {:trace_export, event, run.id, run.kind})
    :ok
  end
end

{outcome, root_id} =
  BeamWeaver.Tracing.with_run("custom-export", [exporter: MyApp.TraceObserver, exporter_opts: [receiver: self()]], fn ->
    result = MyApp.TracedAgent.invoke(%{messages: ["Say hello briefly."]})
    {result, BeamWeaver.Tracing.capture_context().run_id}
  end)

{:ok, _} = outcome

receive do
  {:trace_export, :ok, ^root_id, _kind} -> :ok
after
  1_000 -> raise "Exporter did not receive the completed root run"
end
```

## Metrics with telemetry

Graph events cover start/stop/interrupt/exception, node lifecycle, retries,
timeouts and cancellation. Cache, checkpoint and memory events expose their
operations; provider compatibility events expose rejected features/parameters;
export-queue events expose delivery failures and drops.

Attach handlers once at startup and detach temporary handlers after an
experiment. Keep handlers fast. Run/node duration measurements use native
monotonic units; convert with `System.convert_time_unit/3`. Timeout budgets
are reported in milliseconds. Avoid double-counting parent and child spans
when aggregating total model usage.

## Provider HTTP requests

Req/Finch telemetry describes actual transport activity. BeamWeaver places a
redacted summary in `request.private[:beam_weaver]`. Raw request/response
metadata can still contain credential headers or sensitive bodies: extract
only the fields you need. A successful transport response is one layer of
success; inspect parsed provider outcome and application behavior too.

Observe provider latency without logging authorization headers or request bodies:

```elixir
defmodule MyApp.ProviderLatency do
  def handle_event([:finch, :request, :stop], %{duration: duration}, %{request: request}, receiver) do
    case request.private[:beam_weaver] do
      %{provider: provider} ->
        send(receiver, {:provider_latency, provider, System.convert_time_unit(duration, :native, :microsecond)})

      _ ->
        :ok
    end
  end
end

:ok =
  :telemetry.attach("docs-provider-latency", [:finch, :request, :stop], &MyApp.ProviderLatency.handle_event/4, self())

try do
  model = BeamWeaver.Models.init_chat_model!("openai:gpt-5.4-mini", max_tokens: 128, timeout: 60_000)
  {:ok, _} = BeamWeaver.Core.ChatModel.invoke(model, "Say hello briefly.")

  receive do
    {:provider_latency, provider, duration} when provider in [:openai, "openai"] and duration > 0 -> :ok
  after
    1_000 -> raise "No provider latency event was observed"
  end
after
  :telemetry.detach("docs-provider-latency")
end
```
