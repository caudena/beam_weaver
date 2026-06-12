# BeamWeaver Tracing

BeamWeaver tracing records local run trees for agents, graphs, runnables, model
calls, tool calls, middleware, transport, and replay observability.

Tracing is local by default. External uploads are opt-in through exporters. The
native hosted destination is WeaveScope.

## Native Trace Options

Pass `trace:` to graph, agent, runnable, model, or tool calls when you want
application-level trace identity and searchable dimensions:

```elixir
MyAgent.invoke(input,
  trace: [
    name: "customer_support_agent",
    thread_id: thread.id,
    user_id: thread.user_id,
    session_id: thread.session_id,
    execution_mode: "support_chat",
    fields: %{ticket_id: ticket.id, account_id: account.id},
    metadata: %{feature: "support_inbox"}
  ]
)
```

Standard trace fields are:

| Field | Use |
| --- | --- |
| `:name` | Root run display name. |
| `:thread_id` | Conversation or durable checkpoint thread ID. |
| `:user_id` | Authenticated end-user ID. |
| `:session_id` | Browser/session ID. |
| `:execution_mode` | Workflow mode such as `ai_chat`, `ai_report`, or `background_job`. |
| `:environment` | Optional deployment environment. Include it in `trace:` when you want it exported. |
| `:fields` / `:custom_fields` | Indexed custom dimensions. |
| `:metadata` | Non-indexed details. |

Custom fields are flat searchable dimensions. Use them for IDs you expect to
filter by: `ticket_id`, `case_id`, `tenant_id`, `account_id`, or `workflow_id`.
Values are normalized to strings. Nested values, blank values, private keys, and
secret-like keys such as `api_key`, `token`, `secret`, `password`, and
`authorization` are dropped.

`trace[:thread_id]` is also copied into `config.configurable.thread_id` when no
checkpoint thread ID is already supplied. Use `config.configurable` for
checkpointing and runtime configuration only; do not put public observability
metadata there.

Run kind is inferred from the BeamWeaver execution path. Graph roots, runnables,
model calls, tools, and middleware spans set their own kind internally. Only the
low-level `BeamWeaver.Tracing.start_run/2` API accepts `:kind` for fully manual
runs.

The WeaveScope exporter does not infer or fall back to a configured
environment. If the trace metadata does not include `environment`, exported
events omit it.

## Local API

Start and finish a run:

```elixir
{:ok, run} =
  BeamWeaver.Tracing.start_run("openai request",
    kind: :model,
    inputs: %{prompt: "hello"},
    metadata: %{user_id: 42, custom_fields: %{"ticket_id" => "123"}}
  )

BeamWeaver.Tracing.finish_run(run, outputs: %{text: "hi"})
```

Record failure:

```elixir
BeamWeaver.Tracing.fail_run(run, exception)
```

Wrap code:

```elixir
BeamWeaver.Tracing.with_run("tool call", fn ->
  tool.()
end)
```

Propagate context into supervised tasks:

```elixir
task =
  BeamWeaver.Tracing.async(BeamWeaver.Runtime.TaskSupervisor, fn ->
    BeamWeaver.Tracing.with_run("model call", fn -> call_model.() end)
  end)
```

Graph nodes run in BEAM tasks. BeamWeaver propagates the active tracing context
into those tasks, so model and tool calls inside graph nodes appear as children
of the root graph or agent run instead of detached top-level runs. Child runs
inherit standard metadata such as `thread_id`, `user_id`, `session_id`,
`execution_mode`, and `custom_fields`.

## WeaveScope Export

Configure WeaveScope credentials globally. BeamWeaver automatically uses the
queued WeaveScope exporter when both `endpoint` and `api_key` are configured.

```elixir
config :beam_weaver,
  weave_scope: [
    endpoint: "https://app.weavescope.com",
    api_key: System.fetch_env!("WEAVESCOPE_API_KEY")
  ]
```

For short-lived scripts, call `BeamWeaver.Tracing.flush_exporter/1` before the
VM exits so queued trace uploads drain:

```elixir
BeamWeaver.Tracing.flush_exporter(60_000)
```

The exporter sends BeamWeaver-native observation events. It includes inputs,
outputs, usage, errors, tags, standard trace metadata, and custom fields.
Exporter errors are swallowed by tracing calls so observability failures do not
break user flows.

## Model And Tool Runs

Calls made through `BeamWeaver.Core.ChatModel.invoke/3` create child model runs
when tracing is active. Agent streaming paths that use provider
`stream_response/3` are wrapped the same way. Model runs include:

- input messages
- output messages
- provider and model names
- safe invocation params
- token and cost usage
- structured-output strategy metadata

When tracing is active, `BeamWeaver.Core.Tool.invoke/3` records child tool runs.
Tool inputs contain only public model arguments; runtime-injected state, stores,
runtime structs, and tool runtime fields are filtered out. Tool metadata
includes `tool_name`, `tool_call_id`, description, tags, and safe tool metadata.

Pass `trace?: false` only when you deliberately want to suppress a child run,
such as wrapper tools that delegate to another tool and should not produce a
duplicate nested run.

## Redaction

Inputs, outputs, metadata, usage, and errors are redacted before they are stored.
The redactor protects authorization headers, API keys, bearer tokens,
OpenAI-style secret keys, and common nested secret fields.

## Provider HTTP Telemetry

Live provider calls run through Req and Finch. BeamWeaver does not enable
environment-variable HTTP debug logging. Instead, attach telemetry handlers to
the standard Finch events and read BeamWeaver's redacted provider metadata from
`metadata.request.private[:beam_weaver]`.

Useful events include:

| Event | Use |
| --- | --- |
| `[:finch, :request, :stop]` | Overall request duration and final Req/Finch result. |
| `[:finch, :request, :exception]` | Request-level exceptions. |
| `[:finch, :recv, :stop]` | Response status, response headers, and receive duration. |
| `[:finch, :recv, :exception]` | Receive timeout or protocol failures. |

The BeamWeaver metadata is redacted and summarized. The raw Finch request and
response are still present in telemetry metadata/results, so do not log
`metadata.request` or `metadata.result` wholesale in production handlers.

## Related Guides

- [Event Streaming](event_streaming.md)
- [Persistence](persistence.md)
- [Runtime](runtime.md)
- [Going To Production](going_to_production.md)
- [Replay](replay.md)
