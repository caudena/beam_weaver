# Async Subagents

Async subagents let a supervisor agent launch background work and continue the
conversation while that work runs. The supervisor can later check progress,
send follow-up instructions, cancel a task, or list the tasks it is tracking.

BeamWeaver exposes async subagents through
`BeamWeaver.Agent.Subagent.AsyncSpec` and
`BeamWeaver.Agent.Middleware.AsyncSubagents`. This is a remote-control surface:
the subagent itself runs behind an Agent Protocol-like client, while the
supervisor stores task metadata in its graph state.

Use async subagents when work is long-running, parallelizable, or needs
mid-flight steering. Use [Subagents](subagents.md) when the supervisor should
block until a delegated task returns a final answer.

{% hint style="warning" %}
**Preview Surface**

Async subagents are intentionally small in BeamWeaver. The current implementation
provides the tool surface, task state channel, and a minimal HTTP client. It does
not implement Python's ASGI in-process transport or LangGraph SDK deployment
semantics.
{% endhint %}

## When To Use Async Subagents

| Dimension | Sync subagents | Async subagents |
| --- | --- | --- |
| Execution model | Supervisor waits for the child result. | Supervisor receives a task ID immediately. |
| Concurrency | Isolated work, but blocking from the supervisor's point of view. | Background work can continue while the supervisor responds to the user. |
| Mid-task updates | Not part of the sync task contract. | `update_async_task` sends new instructions to the remote task. |
| Cancellation | Not part of the sync task contract. | `cancel_async_task` asks the remote task to stop. |
| Statefulness | Each task is a fresh child agent run. | The remote task can maintain its own thread or run state; BeamWeaver also tracks metadata in `:async_tasks`. |
| Best for | A result needed before the supervisor can continue. | Long research, coding, analysis, or review jobs managed over several chat turns. |

## Configure Async Subagents

Define async subagents with `BeamWeaver.Agent.Subagent.AsyncSpec`. You can pass
them through `async_subagents`, or include `%AsyncSpec{}` values in
`subagents`; BeamWeaver routes them to the async middleware instead of the sync
`task` tool.

```elixir
alias BeamWeaver.Agent
alias BeamWeaver.Agent.Subagent.AsyncSpec

{:ok, agent} =
  Agent.build(
    name: "supervisor",
    model: BeamWeaver.Models.init_chat_model!("openai:gpt-5.4"),
    system_prompt: """
    Launch async subagents for long-running work. After starting a task, return
    the full task_id to the user and do not poll unless the user asks.
    """,
    async_subagents: [
      AsyncSpec.new(
        name: "researcher",
        description: "Long-running research worker for information gathering and synthesis.",
        graph_id: "researcher",
        url: "https://agents.example.com",
        headers: %{"authorization" => "Bearer #{System.fetch_env!("AGENT_TOKEN")}"}
      ),
      AsyncSpec.new(
        name: "coder",
        description: "Background coding worker for implementation and review.",
        graph_id: "coder",
        url: "https://code-agents.example.com"
      )
    ]
  )
```

Module-defined agents use the `async_subagents do` DSL:

```elixir
defmodule MyApp.SupervisorAgent do
  use BeamWeaver.Agent

  alias BeamWeaver.Agent.Subagent.AsyncSpec

  model BeamWeaver.Models.init_chat_model!("anthropic:claude-sonnet-4-6")

  async_subagents do
    async_subagent "researcher",
      description: "Long-running research worker.",
      graph_id: "researcher",
      url: "https://agents.example.com"
  end
end
```

## AsyncSpec Fields

| Field | Type | Behavior |
| --- | --- | --- |
| `:name` | string | Unique identifier the supervisor passes as `subagent_name` or `subagent_type`. |
| `:description` | string | Model-facing description used to choose which async subagent to launch. |
| `:graph_id` | string | Remote assistant or graph identifier. BeamWeaver sends it as `assistant_id` in the start payload. |
| `:url` | string or `nil` | Base URL for the built-in HTTP client. When present and no client is supplied, BeamWeaver uses `BeamWeaver.Agent.Protocol.ReqClient`. |
| `:client` | module or `nil` | Module implementing `BeamWeaver.Agent.Protocol.Client`. Use this for custom protocols, in-process dispatch, tests, or nonstandard auth. |
| `:headers` | map | Extra headers passed by the built-in HTTP client. Use for remote authentication. |

`AsyncSpec.new/1` accepts keyword lists and atom-keyed maps. If `:url` is
present and `:client` is omitted, it selects
`BeamWeaver.Agent.Protocol.ReqClient`.

{% hint style="warning" %}
**No Implicit ASGI Transport**

In the official Python Deep Agents page, omitting `url` selects ASGI transport
for co-deployed LangGraph graphs. BeamWeaver does not implement that transport.
If both `url` and `client` are omitted, BeamWeaver can still track a local task
record, but checks and updates cannot call a remote worker. Provide `url:` or a
custom `client:` for real background execution.
{% endhint %}

## Tools

`BeamWeaver.Agent.Middleware.AsyncSubagents` adds five model-visible tools:

| Tool | Purpose | Result |
| --- | --- | --- |
| `start_async_task` | Start a background task. | Writes a task record and returns JSON containing the task ID and status. |
| `check_async_task` | Refresh a tracked task. | Returns JSON with current status and result if available. |
| `update_async_task` | Send follow-up instructions. | Appends an update, calls the remote client, and keeps the same task ID. |
| `cancel_async_task` | Cancel a running task. | Marks the task cancelled or merges the remote cancellation status. |
| `list_async_tasks` | List tracked tasks. | Refreshes non-terminal tasks and returns a concise summary. |

In practice, `start_async_task` needs a task `description` and a
`subagent_name` or `subagent_type`. The JSON Schema only marks `description` as
required so the model can recover from omitted names, but useful calls should
always include the name.

## Lifecycle

A typical async task flows through these steps:

1. The supervisor calls `start_async_task` with a subagent name and task
   description.
2. BeamWeaver calls `Client.start_task/3` with the async spec and this payload:

   ```elixir
   %{
     assistant_id: async_spec.graph_id,
     input: %{messages: [%{role: "user", content: description}]}
   }
   ```

3. The remote response is merged into a task record. BeamWeaver chooses the task
   ID from `thread_id`, `task_id`, `id`, or `run_id` in that order. If no remote
   ID is returned, it generates an `async-...` ID.
4. The supervisor returns that full task ID to the user.
5. Later, the supervisor calls `check_async_task`, `update_async_task`,
   `cancel_async_task`, or `list_async_tasks`.

The built-in HTTP client maps operations to these endpoints:

| Operation | HTTP request |
| --- | --- |
| Start | `POST /runs` with the start payload. |
| Check | `GET /runs/:task_id`. |
| Update | `POST /runs/:task_id/input` with `%{message: message}`. |
| Cancel | `POST /runs/:task_id/cancel`. |

Remote responses can include `status`, `result`, `thread_id`, `run_id`, `id`,
or nested `values.messages`. When no explicit result exists, BeamWeaver tries to
extract the final non-empty message content from `values.messages`.

## State Management

Async task metadata lives in a dedicated `:async_tasks` graph state channel.
This keeps task IDs available even if message history is summarized or compacted.

Each task record includes:

| Field | Meaning |
| --- | --- |
| `:id` / `:task_id` | Stable task ID used for check, update, cancel, and list. |
| `:subagent_name` | Async subagent name. |
| `:graph_id` and `:url` | Remote target metadata from the spec. |
| `:thread_id` and `:run_id` | Remote IDs when returned by the client. |
| `:status` | Current cached status, such as `"running"`, `"success"`, `"complete"`, `"error"`, or `"cancelled"`. |
| `:created_at`, `:last_checked_at`, `:last_updated_at` | ISO timestamps maintained by the middleware. |
| `:description` | Original task description. |
| `:updates` | Follow-up messages sent through `update_async_task`. |
| `:remote` | Last raw remote response. |
| `:result` | Extracted final result when available. |

`list_async_tasks` refreshes non-terminal tasks before summarizing them.
Terminal statuses are cached. BeamWeaver treats `cancelled`, `success`, `error`,
`timeout`, `interrupted`, `complete`, and `completed` as terminal for refresh
purposes.

## Custom Clients

Implement `BeamWeaver.Agent.Protocol.Client` when the built-in HTTP shape does
not match your server:

```elixir
defmodule MyApp.AgentProtocolClient do
  @behaviour BeamWeaver.Agent.Protocol.Client

  @impl true
  def start_task(async_spec, payload, _opts) do
    # Start remote or in-process work.
    {:ok, %{"thread_id" => "task-123", "status" => "running", "payload" => payload}}
  end

  @impl true
  def check_task(_async_spec, task_id, _opts) do
    {:ok, %{"thread_id" => task_id, "status" => "complete", "result" => "done"}}
  end

  @impl true
  def update_task(_async_spec, task_id, message, _opts) do
    {:ok, %{"thread_id" => task_id, "status" => "running", "last_message" => message}}
  end

  @impl true
  def cancel_task(_async_spec, task_id, _opts) do
    {:ok, %{"thread_id" => task_id, "status" => "cancelled"}}
  end
end
```

Then attach it to a spec:

```elixir
AsyncSpec.new(
  name: "researcher",
  description: "Research worker.",
  graph_id: "researcher",
  client: MyApp.AgentProtocolClient
)
```

Custom clients are the right place to implement auth, internal service
discovery, retries, telemetry, or non-HTTP transports.

## Deployment Topologies

BeamWeaver does not prescribe a deployment platform. The useful topologies are:

| Topology | BeamWeaver shape |
| --- | --- |
| Single BEAM app with internal workers | Use a custom `client:` that starts supervised local work and stores task state in your application. |
| Remote Agent Protocol server | Use `url:` with `ReqClient`, or a custom client if the server shape differs. |
| Split supervisor and workers | Give each `AsyncSpec` a different `url:` or `client:`. |
| Hybrid | Mix local custom clients and remote URLs in the same `async_subagents` list. |

Capacity planning belongs to the worker service. In local Elixir development,
that may mean sizing a `Task.Supervisor`, Oban queue, Broadway pipeline, or
remote deployment pool. In remote LangGraph deployments, follow the platform's
worker configuration.

## Best Practices

- Write precise descriptions so the supervisor chooses the right async worker.
- Tell the supervisor prompt to return control to the user after launch and not
  poll immediately.
- Always show and preserve the full task ID.
- Treat statuses in old conversation messages as stale. Call `check_async_task`
  or `list_async_tasks` before reporting current status.
- Put credentials in `headers`, application config, or a custom client. Do not
  put secrets in prompts.
- Keep remote response shapes predictable: return `status`, a stable ID, and
  `result` when complete.
- Add telemetry and retry policy in custom clients when remote reliability
  matters.

## Troubleshooting

| Problem | Cause | Fix |
| --- | --- | --- |
| The supervisor polls immediately after launch. | The model is trying to turn async work into a blocking workflow. | Reinforce in `system_prompt`: after `start_async_task`, return the full task ID and wait for user follow-up. |
| The supervisor reports stale status. | It reused an old tool message instead of refreshing. | Add prompt guidance to call `check_async_task` or `list_async_tasks` before status reports. |
| `check_async_task` returns `"unknown"`. | The task ID is missing from `:async_tasks`, often because the ID was truncated or came from another thread. | Use the full task ID and keep the same checkpointer/thread config. |
| The task starts but never changes status. | The spec has no `url` or `client`, or the remote server always returns cached/running status. | Provide a real client, configure `url:`, or fix the worker response. |
| `Unknown async subagent type`. | `subagent_name` / `subagent_type` does not match any configured `AsyncSpec.name`. | Improve descriptions and ensure the model uses the exact configured name. |
| Remote auth fails. | The built-in HTTP client only sends the configured `headers`. | Add the correct headers or implement a custom client for the provider. |
| Launches queue or hang. | Worker capacity is exhausted or remote runs are serialized. | Increase worker capacity in the worker service. |

## Related Guides

- [Subagents](subagents.md)
- [Composed Agent Capabilities](agent_harness.md)
- [Context Engineering](context_engineering.md)
- [Prebuilt Middleware](prebuilt_middleware.md)
- [Runtime](runtime.md)
- [Event Streaming](event_streaming.md)
