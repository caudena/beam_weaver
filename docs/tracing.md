# BeamWeaver Tracing

BeamWeaver tracing records local run trees. It is the boundary for agent, model,
tool, graph, transport, and replay observability.

Tracing is local by default. External uploads are opt-in through exporters.

## API

Start and finish a run:

```elixir
{:ok, run} =
  BeamWeaver.Tracing.start_run("openai request",
    kind: :model,
    inputs: %{prompt: "hello"}
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

## Redaction

Inputs, outputs, metadata, usage, and errors are redacted before they are stored.
The redactor protects authorization headers, API keys, bearer tokens, OpenAI-style
secret keys, and common nested secret fields.

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

Example:

```elixir
require Logger

:telemetry.attach_many(
  "beam-weaver-provider-http",
  [
    [:finch, :request, :stop],
    [:finch, :request, :exception],
    [:finch, :recv, :stop],
    [:finch, :recv, :exception]
  ],
  fn event, measurements, metadata, _config ->
    provider =
      case metadata[:request] do
        %{private: private} -> private[:beam_weaver]
        _other -> nil
      end

    if provider do
      Logger.info(
        "provider_http event=#{Enum.join(event, ".")} " <>
          "provider=#{inspect(provider.provider)} " <>
          "url=#{inspect(provider.url)} " <>
          "timeout_ms=#{inspect(provider.timeout_ms)} " <>
          "duration=#{inspect(measurements[:duration])} " <>
          "summary=#{inspect(provider.request_body_summary)}"
      )
    end
  end,
  nil
)
```

The BeamWeaver metadata is redacted and summarized. The raw Finch request and
response are still present in telemetry metadata/results, so do not log
`metadata.request` or `metadata.result` wholesale in production handlers.

## Exporters

Exporters implement `BeamWeaver.Tracing.Exporter`. Exporter errors are swallowed
by tracing calls so observability failures do not break user flows.

Configure an exporter globally:

```elixir
config :beam_weaver,
  tracing: [exporter: MyApp.TraceExporter]
```

BeamWeaver includes a queued LangSmith-compatible exporter. This is the
recommended production configuration because graph starts and finishes can be
coalesced before upload. The queue uses a short SDK-style aggregation window
by default (`flush_interval: 250` ms), so fast start/finish pairs are uploaded
as one batch operation while longer runs are created first and patched when
they finish:

```elixir
config :beam_weaver,
  tracing: [exporter: BeamWeaver.Tracing.Exporters.LangSmith.Queue],
  langsmith: [
    api_key: System.fetch_env!("LANGSMITH_API_KEY"),
    project: System.get_env("LANGSMITH_PROJECT", "default"),
    flush_interval: 250
  ]
```

Set `LANGSMITH_API_KEY`, and optionally `LANGSMITH_ENDPOINT` and
`LANGSMITH_PROJECT`, or pass those as exporter options.

For one-off tests you can use the synchronous HTTP exporter directly:

```elixir
config :beam_weaver,
  tracing: [exporter: BeamWeaver.Tracing.Exporters.LangSmith]
```

If you also enable `config :beam_weaver, langsmith: [telemetry?: true]`,
BeamWeaver forwards selected low-level telemetry events such as cache,
checkpoint, memory, vector store, and model parameter events. Those events are
supplemental diagnostics. They do not replace the tracing exporter, which is
what carries the agent or graph input and output payloads. Stream events are not
forwarded as LangSmith runs because they only contain counters such as
`%{count: 1}` and duplicate the real trace tree.

### Model Runs in LangSmith

Graph and agent execution create a root `chain` run. Calls made through
`BeamWeaver.Core.ChatModel.invoke/3` create child `llm` runs when tracing is
active. Agent streaming paths that use provider `stream_response/3` are wrapped
the same way. These model runs include:

* `inputs.messages`
* `outputs.generations`
* `outputs.llm_output`
* `extra.invocation_params`
* `extra.metadata.ls_integration`
* `extra.metadata.ls_message_format`
* `extra.metadata.ls_provider`
* `extra.metadata.ls_model_name`
* `extra.metadata.usage_metadata`

LangSmith uses the exported `outputs.generations` `LLMResult` shape,
`ls_integration`, and `ls_message_format` to render chat messages in the trace
UI. It uses `outputs.llm_output`, `ls_provider`, `ls_model_name`, and
`usage_metadata` to populate model and token details. BeamWeaver also stores the
same provider/model values under `model_provider` and `model_name` for local
correlation.

Graph nodes run in BEAM tasks. BeamWeaver propagates the active tracing context
into those tasks, so model calls inside graph nodes appear as children of the
root graph run instead of as detached top-level runs.

Child runs also need a LangSmith `dotted_order` that includes their parent
segment. BeamWeaver derives that parent segment from the stored parent run when
exporting the child, so normal nested model/tool runs produce SDK-style dotted
orders like `parent.child`.

If you bypass `BeamWeaver.Core.ChatModel` and call a provider module directly,
BeamWeaver cannot attach model metadata automatically. Wrap that call with
`BeamWeaver.Tracing.with_run(..., kind: :model, ...)` or route it through
`ChatModel.invoke/3`. Pass `trace?: false` to a model call only when you
deliberately want to suppress the child model run.

### Tool Runs in LangSmith

When tracing is active, `BeamWeaver.Core.Tool.invoke/3` records a neutral child
run with `kind: :tool`. Tool runs store BeamWeaver-native metadata such as
`tool_name`, `tool_call_id`, `description`, tool tags, and tool metadata.
Inputs contain only public model arguments; runtime-injected state, stores,
runtime structs, and tool runtime fields are filtered out.

`ToolNode` does not create its own chain run by default. This matches LangGraph:
the graph or agent root is the parent run, and each actual tool execution is a
child tool run. Unknown tools and middleware short-circuits do not create tool
runs because no registered tool executed. Middleware that retries by invoking
the same handler more than once creates one tool run per attempt, all with the
same `tool_call_id`.

When provider-native IDs differ from executable tool IDs, the LangSmith exporter
uses the executable ID for trace linking. Tool-call exports prefer `call_id`,
then `tool_call_id`, then local `id`, then `provider_id`. This keeps OpenAI/xAI
provider IDs such as `fc_*` out of LangSmith's executable tool edge.

Handled validation or tool errors finish the tool run successfully with the
handled error result as the output. Unhandled validation errors and exceptions
fail the tool run. Pass `trace?: false` only inside wrapper tools that delegate
to another tool and should not produce a nested duplicate run.

The LangSmith exporter keeps this compatibility work at the export boundary.
BeamWeaver run structs do not contain LangSmith-only `serialized` or `events`
fields. During export, model inputs and outputs receive LangChain-compatible
chat message constructors and `outputs.generations`. Tool runs receive a
LangSmith-style `serialized` shape, SDK-style lifecycle events,
`extra.tool_call_id`, and a LangChain-like `outputs.output` tool-message
payload. Graph and agent root payloads also get
`extra.metadata.ls_integration = "langgraph"` during export without mutating
local BeamWeaver metadata.

Structured-output tool strategy uses pseudo tools to get schema-shaped model
responses. Those schema calls are not executable application tools, so the
LangSmith exporter strips them from exported tool-call lists and provider
content blocks. Raw provider fields such as `raw_provider_block`,
`raw_provider_response`, and `provider_metadata` are also removed at the export
boundary. Internal graph bookkeeping channels such as `__node_outputs__` and
`__edge_runs__` are not uploaded.

### LangSmith Export Failures

Tracing calls are not allowed to break user flows. `BeamWeaver.Tracing` catches
and ignores exporter failures from the synchronous `export/3` boundary. That
means setting `Logger.configure(level: :debug)` does not, by itself, make
LangSmith API response bodies appear in logs. You will only see them if your
application, custom exporter, queue telemetry handler, or transport wrapper logs
them. Non-success LangSmith HTTP responses include a bounded `:response_body`
detail in the returned exporter error so queue telemetry can include the API
reason without making trace export failures fatal.

The queued LangSmith exporter emits telemetry for upload results:

| Event | Use |
| --- | --- |
| `[:beam_weaver, :langsmith, :queue, :upload_success]` | Count accepted uploads. |
| `[:beam_weaver, :langsmith, :queue, :upload_failure]` | Log sanitized API failures and retry scheduling. |
| `[:beam_weaver, :langsmith, :queue, :dead_letter]` | Alert after retry exhaustion. |

Attach a handler when debugging production export issues:

```elixir
require Logger

:telemetry.attach(
  "log-langsmith-upload-failures",
  [:beam_weaver, :langsmith, :queue, :upload_failure],
  fn _event, _measurements, metadata, _config ->
    Logger.warning(
      "langsmith export failed " <>
        "project=#{inspect(metadata.metadata.project)} " <>
        "run_id=#{inspect(metadata.run_id)} " <>
        "error=#{inspect(metadata.error)}"
    )
  end,
  nil
)
```

The exporter intentionally does not log by itself. If you need request payloads
or headers for a one-off investigation, log them in a sanitizing transport
wrapper or test transport so trace inputs, outputs, and credentials do not leak
into application logs.

Batch exports use the SDK-style `/runs/multipart` endpoint first. Each run
operation is split into multipart fields such as `post.<id>`,
`post.<id>.inputs`, `patch.<id>.outputs`, and `patch.<id>.extra`. If the
server does not support multipart uploads, BeamWeaver falls back to the
`/runs/batch` object shape with `post` and `patch` lists, and finally to
individual run uploads if the batch endpoint is unavailable too.

When a create and later update for the same run are flushed through the JSON
batch fallback, BeamWeaver coalesces them into one `post` payload, matching the
SDK's queue serialization behavior. Update payloads omit absent `inputs` and
`outputs`, so metadata-only updates cannot erase the real graph input or final
output during coalescing. A `422` response that says the server cannot unmarshal
an array means the caller is sending the wrong batch JSON shape.

Like the official SDK, run starts are sent as creates and run finishes or
failures are sent as patches. If you only see diagnostic rows such as
`beam_weaver.graph.start` with `%{measurements: ...}` input and no output,
LangSmith telemetry is enabled but tracing export is not wired to
`BeamWeaver.Tracing.Exporters.LangSmith.Queue`.

LangSmith can return `409` with `payloads already received` when the same run
payload is retried after the server has already accepted it. BeamWeaver treats
that conflict as an idempotent success, matching the official SDK behavior, so
the queue drops the item instead of retrying and logging repeated upload
failures.

Before upload, the exporter also encodes arbitrary trace values into
JSON-safe data, mirroring the official SDK's serializer boundary. Message
structs, dates, times, tuples, `MapSet`s, atoms, invalid UTF-8 binaries, and
custom structs are converted before they are placed in `inputs`, `outputs`,
`extra.metadata`, `extra.usage`, tags, or captured error response bodies. This
keeps LangSmith uploads from failing because an otherwise valid BeamWeaver term
cannot be encoded as JSON.

BeamWeaver-generated graph and trace run IDs are UUIDv7 strings. This matches
the LangGraph and Deep Agents production examples, where each conversation gets
a stable unique `thread_id`, and it also keeps LangSmith-facing run identifiers
UUID-shaped. Explicit caller-provided IDs are still preserved, so tests,
integrations, and older queued telemetry may still contain values such as
`graph_run_S` or `run_stream`. Those are local BeamWeaver IDs, not
LangSmith-generated IDs. The LangSmith exporter normalizes any non-UUID local
ID to a deterministic UUID in the API payload and keeps the original values in
`extra.metadata.beam_weaver_run_id` and
`extra.metadata.beam_weaver_trace_id` for correlation. LangSmith
`dotted_order` values use the SDK format
`YYYYMMDDTHHMMSSffffffZ<run_uuid>` for each run segment.

## Related Guides

- [Event Streaming](event_streaming.md)
- [Persistence](persistence.md)
- [Runtime](runtime.md)
- [Going To Production](going_to_production.md)
- [Replay](replay.md)
