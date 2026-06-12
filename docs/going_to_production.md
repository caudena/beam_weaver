# Going To Production

BeamWeaver does not provide a hosted deployment platform, `langgraph.json`, or
managed agent server. Production is your Elixir application: OTP supervision,
releases, config, database migrations, schedulers, telemetry, and whatever HTTP
or job boundary invokes your agents and graphs.

Use this page as a checklist and routing guide. The implementation details live
in the linked topic pages so this guide stays small and avoids duplicating
memory, sandbox, persistence, guardrail, and streaming docs.

## Production Contract

Every production invocation should separate conversation identity from trusted
run context:

```elixir
config = %{"configurable" => %{"thread_id" => "thread-123"}}

context = %{
  user_id: "user-123",
  org_id: "org-456",
  permissions: ["support:read"],
  request_id: "req-789"
}

MyApp.SupportAgent.invoke(input, config: config, context: context)
```

`thread_id` scopes checkpointed conversation state. Reuse it for follow-up turns
in the same conversation and generate a new one for a separate thread.

`context` carries per-run facts supplied by your application boundary: user ID,
tenant, permissions, feature flags, locale, request IDs, and credential handles.
Do not let the model choose ownership values. Derive them from authenticated
request/session state and pass them through `context:` or `server_info:`.

## Identity And Tenancy

BeamWeaver has no built-in user system. Your application should authenticate the
request, authorize access, and pass only trusted identity into BeamWeaver.

| Scope | Use |
| --- | --- |
| Thread | Conversation history, checkpoints, scratch files, and resumable interrupts. |
| User | Private memory, private files, and per-user tools or credentials. |
| Agent | Shared configuration for one agent module or assistant-like deployment. |
| Organization | Shared policies, compliance rules, and organization knowledge. Prefer read-only access. |

For memory and filesystem namespaces, derive scope from trusted runtime context:
`user_id`, `org_id`, agent name, or assistant ID from your own service layer.

See [Runtime](runtime.md), [Persistence](persistence.md), [Memory](memory.md),
and [Filesystem](filesystem.md).

## Deployment Shape

Run BeamWeaver like any other OTP application:

- start agents, queues, stores, and telemetry subscribers under supervision;
- use releases and runtime config for provider keys and endpoint URLs;
- run Ecto migrations for checkpoint, memory, and queue tables;
- use Oban, Quantum, Kubernetes CronJobs, or another scheduler for background
  consolidation and maintenance work;
- expose your own HTTP, Phoenix Channel, LiveView, or job interface around
  `invoke/3`, `stream_events/3`, and resume APIs.

Do not rely on LangGraph Platform conventions such as `langgraph.json`, hosted
thread APIs, or automatic deployment infrastructure. Integrate those
as external services only where your application explicitly chooses to.

## Checklist

| Concern | Production decision | BeamWeaver docs |
| --- | --- | --- |
| Conversation state | Use a checkpointer and stable `thread_id`. | [Persistence](persistence.md), [Short-Term Memory](short_term_memory.md) |
| Durable execution | Pick durable adapters and node boundaries; set timeouts and recursion limits. | [Durable Execution](durable_execution.md), [Fault Tolerance](fault_tolerance.md) |
| Human review | Use checkpointed HITL for sensitive tools and resumable approvals. | [Human-In-The-Loop](human_in_the_loop.md) |
| Long-term memory | Scope by user, agent, or org; make shared policy memory read-only. | [Memory](memory.md), [Long-Term Memory](long_term_memory.md) |
| Files | Pick local, store-backed, composite, or sandbox-backed filesystems. | [Filesystem](filesystem.md), [Permissions](permissions.md) |
| Code execution | Use sandbox adapters for untrusted command execution; keep secrets outside sandboxes. | [Sandboxes](sandboxes.md) |
| Skills | Load only the skill sources each agent or subagent should see. | [Skills](skills.md), [Subagents](subagents.md) |
| Model usage | Set model timeouts, retry/fallback policy, and provider limits. | [Models](models.md), [Fault Tolerance](fault_tolerance.md), [Rate Limiting](rate_limiting.md) |
| Tool usage | Restrict tools, add HITL where needed, and limit or retry external API tools deliberately. | [Tools](tools.md), [Guardrails](guardrails.md), [Prebuilt Middleware](prebuilt_middleware.md) |
| Sensitive data | Redact tracing data and avoid putting credentials in model-visible state. | [Tracing](tracing.md), [Guardrails](guardrails.md), [Sandboxes](sandboxes.md) |
| Streaming UI | Consume one event stream and route typed envelopes to your UI or transport. | [Event Streaming](event_streaming.md) |
| Observability | Attach telemetry, export traces intentionally, and monitor exporter queues. | [Tracing](tracing.md) |
| Tests | Run integration tests for the adapters and workflows you deploy. | [Replay](replay.md) |

## Invocation Patterns

For request/response APIs, call `invoke/3` from a supervised request handler or
job process:

```elixir
case MyApp.SupportAgent.invoke(input, config: config, context: context) do
  {:ok, state} -> {:ok, state}
  {:interrupted, interrupt} -> {:needs_review, interrupt}
  {:error, error} -> {:error, error}
end
```

For live UIs, call `stream_events/3` and forward typed envelopes through your
transport:

```elixir
{:ok, events} =
  MyApp.SupportAgent.stream_events(input,
    config: config,
    context: context,
    live: true
  )

Enum.each(events, fn envelope ->
  MyAppWeb.AgentChannel.push_event(socket, envelope)
end)
```

Consume a live stream once. If multiple UI components need the same updates,
fan out from one process through PubSub, channels, LiveView assigns, or your own
projection state.

## Secrets

Keep provider API keys, OAuth tokens, database credentials, and customer secrets
outside model-visible state. Prefer host-side tools that perform authenticated
work without exposing the credential to the model or sandbox.

For sandboxed code execution:

- do not upload secrets as files;
- do not inject broad environment variables into the sandbox;
- restrict network access where possible;
- treat sandbox outputs as untrusted input;
- implement credential proxying or host-side tools when sandbox code must call
  authenticated APIs.

See [Sandboxes](sandboxes.md), [Tools](tools.md), and [Guardrails](guardrails.md).

## Background Work

Use normal Elixir scheduling and jobs for production maintenance:

- memory consolidation across recent conversations;
- trace export queue flushing and dead-letter handling;
- checkpoint pruning and retention;
- sandbox cleanup by thread or agent scope;
- index refresh and retrieval ingestion;
- eval or conformance jobs against production-like adapters.

These are application jobs, not BeamWeaver-specific hosted cron features. Use
Oban or your existing scheduler and invoke BeamWeaver agents, graphs, memory
stores, and checkpoint APIs from those jobs.

## Related Guides

- [Runtime](runtime.md)
- [Persistence](persistence.md)
- [Memory](memory.md)
- [Filesystem](filesystem.md)
- [Permissions](permissions.md)
- [Sandboxes](sandboxes.md)
- [Human-In-The-Loop](human_in_the_loop.md)
- [Fault Tolerance](fault_tolerance.md)
- [Guardrails](guardrails.md)
- [Event Streaming](event_streaming.md)
- [Tracing](tracing.md)
