# Changelog

## Unreleased

This release removes compatibility surfaces that nothing inside BeamWeaver
used, replaces them with plain Elixir, and fixes the problems the
documentation rewrite found. New features come first, each with a link to its
guide. Breaking changes follow, grouped by area with security first, each with
what to do instead. Then come the other security fixes, the other changes, bug
fixes and documentation.

### New features

#### Agents

**Capability profiles.** The `capability_profile` declaration (and
`BeamWeaver.Agent.build/1` option) applies a
`BeamWeaver.Agent.CapabilityProfile`: `capability_profile :auto` uses the
profile of the agent's model, and a profile or `CapabilityProfileConfig`
struct is used as given. Its `prompt_suffix` goes after the system prompt,
also after the prompt a `DynamicPrompt` builds, `base_system_prompt` is used
when the agent declares none, its excluded tools and tool descriptions join
`exclude_tools` and `tool_descriptions` (the agent's own descriptions win),
and its middleware runs after the agent's. See [Capability
Profiles](docs/profiles.md#apply-a-profile).

**Timeouts on agent and graph modules.** Agent and graph modules declare
`step_timeout`, `run_timeout` and `tool_timeout`, and
`BeamWeaver.Agent.build/1` takes the same options. `tool_timeout` limits each
tool call; a slow call returns a tool error message to the model. See [Durable
Execution](docs/durable_execution.md#timeouts) and [Going to
Production](docs/going_to_production.md#bound-every-run).

**Structured output that corrects itself.** With the tool strategy, an answer
that fails the schema stays in the conversation with an error tool message
that says what is wrong (missing keys, wrong types), and the model answers
again. `response_schema ..., max_retries: n` (and `StructuredOutput.tool/2`'s
`:max_retries`, default 2) bounds how often, up to `max_retries` times; then
the run fails with the last error, with `attempts` in its details.
`handle_errors: false` fails the run on the first failing answer. See
[Structured Output](docs/structured_output.md#validation-errors-and-retries).

**More context types.** `context_schema` fields accept `:float`, `:decimal`,
`:date`, `:time`, `:utc_datetime`, `:naive_datetime`, `{:list, type}` and
`{:union, types}`. `:float` and `:date` fields used to reject every value. See
[Runtime Context](docs/runtime_context.md#declare-the-context-an-agent-needs).

#### Middleware

**Summarize on context overflow.** When automatic summarization is on, a
model call that the provider rejects as too long for the model summarizes the
thread, whether the trigger was reached or not, and is sent once more. The
summary is saved as an automatic one is when that call succeeds; a second
overflow returns the error. With `overflow_recovery` as well, the agent
gives its `Summarization` to `OverflowRecovery` (the new `summarization:`
option), which clips the trailing tool results first and summarizes only
when that isn't enough, wherever the two are in the middleware list; that
`Summarization` leaves overflows to it (the new `on_overflow: false`).
Subagents that summarize do the same. See [Context
Management](docs/context_management.md#recover-from-context-overflow-errors).

**Media a model can't take is left out.** Before each model call, every
agent and subagent replaces the images and inline PDFs in user and tool
messages that the called model's built-in profile says it can't take
(`image_inputs`, `pdf_inputs`) with a short notice, such as `[report.pdf was
left out: this model doesn't take PDFs.]`. The new `UnsupportedMedia`
middleware runs after the agent's own, so it checks the model that
`ModelFallback` picked, and the thread keeps the media. A model with a
`profile:` of your own, or none, gets the media as it is. See
[Models](docs/models.md#images-and-pdfs).

**A summarizer function for `compact_conversation`.** The
`compact_conversation` declaration and `CompactConversation` take
`summarizer:`, a function of the messages to summarize that returns the
summary text, `{:ok, text}` or `{:error, error}`, as `Summarization` does.
It writes the tool's summaries instead of `model:`, and, like the
declaration's `model:`, the automatic summaries of the agent and its
subagents unless `summarization:` sets its own. See [Context
Management](docs/context_management.md#let-the-agent-compact-itself).

**ToolError.** The new `ToolError` middleware decides what the model reads
when a tool fails, or stops the run instead: its `on_error:` function takes
the error and the tool call request, and returns the text or `nil`. `tools:`
limits it to some tools. See
[ToolError](docs/builtin_middleware.md#toolerror).

**AutoMode.** The new `AutoMode` middleware runs low-risk calls of the tools
you name and blocks risky ones. Before each call it asks a decision model
(`classifier:`, TypeSafe's `"typesafe:jev-latest"` unless you pass another)
how likely the call is to be risky or not clearly authorized by the user,
giving it the call, the tool's description and the last 30 messages. A call at
or above 0.5 gets an error tool message instead of running. It fails closed: a
call the classifier declines is blocked, and a classifier error fails the run
without running the tool. `instructions:` replaces the question. See [Block
risky tool calls](docs/guardrails.md#block-risky-tool-calls).

**Summarization that recovers and fits the model.** `Summarization` tries a
failed summary call up to 3 times, a second or more apart, unless its error
says retrying can't help, and sends a summary prompt that is over the model's
context window once more with the middle of the old messages cut out; when the
call still fails, the run returns its error and the thread stays as it was.
`summarizer:` writes the summary instead of `model:`: a function that takes
the messages to summarize and returns the text, `{:ok, text}` or
`{:error, error}`. `max_input_tokens:` is the context window of the agent's
model, which `{:fraction, f}` triggers and `keep:` settings are taken of:
`compact_conversation` sets it from the agent's model, and the general-purpose
subagent, and a subagent with `base_middleware: [:deepagents]` or
`Summarization` in its `base_middleware`, from the subagent's own model.
`compact_conversation` takes `summarization:`, the `Summarization` options for
the automatic summarization it turns on, or `false` to keep only the tool. See
[Summarization](docs/builtin_middleware.md#summarization) and [Context
Management](docs/context_management.md#summarize-old-messages).

**ToolSelection retries.** `ToolSelection` asks again, up to `max_retries:`
times (1 by default), for a selection reply without a list of tools; then
`on_parsing_failure:` decides: `:error` (the default), `:none`, `:all`, a list
of tool names, or a function of the reply. See
[ToolSelection](docs/builtin_middleware.md#toolselection).

**Your own token counter for ContextEditing.** `ContextEditing` takes
`token_counter:`, a function of a message list that returns its token count,
in place of `token_count_method:`. See
[ContextEditing](docs/builtin_middleware.md#contextediting).

**Redacted streams.** `PII.stream_transform/1` also edits the reasoning and
tool-call arguments a model streams (the reasoning blocks of a `MessageChunk`,
`ToolCallChunk` events and a `MessageChunk`'s tool-call chunks), holding back
their last characters like text; the reasoning of a whole `Message`; tool
events (the input of `ToolStart`, the output a tool streams in `ToolDelta`,
held back until the tool finishes, the output of `ToolFinish` and the message
of `ToolError`); and state snapshots (`GraphValue`). It edits the events only,
never the saved thread. See [Redact a
stream](docs/streaming.md#redact-a-stream).

#### Human review and durable runs

**One review per tool call.** `HumanInTheLoop` takes
`interrupt_mode: :per_call`, which reviews each call on its own as it starts.
Every call of the turn runs as a task of its own, calls that need no review
run straight away and don't run again, and each call that does pauses with a
`"tool_approval"` interrupt: the call, its description, the decisions it
allows and the arguments schema an edit must match. `resume_review/3` answers
them with a map from interrupt id to decision, all at once or one at a time,
or with one decision when one call waits. An edit keeps the tool, and an
answer that doesn't fit fails the resume with `:invalid_human_decision` while
the call waits for another. Tools marked `concurrent false` don't wait for
each other in this mode. See [One pause per
call](docs/human_in_the_loop.md#one-pause-per-call).

**Describe and check an answer.** `Graph.interrupt/2` takes
`response_schema:`, a JSON-schema map or a `BeamWeaver.Schema` module, for
the answer the node expects. The interrupt carries it as JSON schema in
`response_schema`, in the run's result, `get_state/1` and the stream, so a
client can build its form from it, and the resume value is checked against
it: an object answer comes back with string keys, and one that doesn't match
fails the run with `:invalid_resume` (`details.interrupt_id` names the
interrupt) without retrying the node or running its `error_handler:`, while
the interrupt waits for another answer. This works inside subgraphs and
subagents, and for a tool of a call sent to a `ToolNode`. See [Check the
answer](docs/human_in_the_loop.md#check-the-answer).

**Every pause of a step.** A paused run lists every interrupt of its step in
`interrupts`, so pauses in parallel branches or tasks can be answered without
`get_state/1`. `BeamWeaver.Agent.resume_review/3` takes a built agent too. See
[Several pauses at once](docs/human_in_the_loop.md#several-pauses-at-once).

**Review inside subagents.** A subagent that pauses for human review pauses
the parent: `invoke/2` returns `{:interrupted, interrupt}` with the subagent's
review (`review.metadata.subagent_name` names it), and `resume/3` or
`resume_review/3` on the parent resumes the subagent. Before, the `task` tool
returned `"Subagent interrupted: ..."` and the tool never ran. Subagents that
pause in the same turn are reviewed one at a time; when the parent resumes,
subagents that already finished return their saved answer instead of running
again. Decisions that don't fit the review fail the parent's resume with
`:invalid_human_decision`. See [Subagents](docs/subagents.md#human-review).

**Continue a run where it stopped.** `invoke/2` and `stream_events/2` with an
empty input continue the thread's latest checkpoint when its last run stopped
before the end (a crash, a deploy or a breakpoint): they run the steps in
`next` instead of starting over from the first node. On a finished thread an
empty input still starts a new run, and passing `snapshot.config` keeps
working. `resume/2` continues the thread's latest checkpoint too, and on a
thread with nothing left to run it returns the state instead of starting a new
run. Continuing a thread runs past the breakpoint (`interrupt_before`) it
stopped at, also with `invoke(%{}, config: snapshot.config)`; the breakpoint
pauses again when the run reaches its node later. See [Durable
Execution](docs/durable_execution.md#what-survives-a-crash) and [Deploys and
resuming runs](docs/going_to_production.md#deploys-and-resuming-runs).

#### Subagents and deep agents

**Async subagents know who launched them.** Every
`BeamWeaver.Agent.Protocol.Client` callback gets `parent:` in its opts: the
parent's `thread_id` and `run_id`, the `tool_call_id` of the async tool call,
the `subagent_name`, and the parent's `trace_id` and `trace_run_id`. A client
can use them to run the subagent in its parent's sandbox, nest its trace
under the parent's or find a parent's tasks.
`BeamWeaver.Agent.Protocol.ReqClient` sends the `subagent_name` and the
`parent_thread_id` as `metadata` when it starts or updates a task; trace ids
stay in the application. See
[Subagents](docs/subagents.md#async-subagents).

**The general-purpose subagent, configured.** A
`BeamWeaver.Agent.GeneralPurposeSubagentProfile` in a `subagents` list
configures the built-in `general-purpose` subagent: `description:` and
`system_prompt:` replace its texts, and `enabled: false` leaves it out.
Before, `enabled` was never read. See [The general-purpose
subagent](docs/subagents.md#the-general-purpose-subagent).

**Subagent streams.** Subagent runs stream into the parent's stream, live or
collected: their events carry the namespace `["tools", "subagent.<name>"]` and
`subagent_name` and `tool_call_id` in the envelope metadata.
`Agent.Subagent.StreamTransformer` builds one `RunStream` per `task` call from
them (status, values, updates, nested runs). See
[Subagents](docs/subagents.md#streaming).

**Subagents take every agent option.** `Agent.Subagent.Spec` takes every
`BeamWeaver.Agent.build/1` option (`model_opts`, `recursion_limit`,
`context_schema`, `memory`, `subagents`, `checkpointer`, `store`,
`compact_conversation`, `tool_timeout`, `step_timeout`, `run_timeout`,
`capability_profile`, ...), and so does a `subagent MyAgent, opts` line.
`Agent.Subagent.Compiled` takes `recursion_limit`. See [Declare
subagents](docs/subagents.md#declare-subagents).

#### Graphs and streaming

**Choose the events you stream.** `stream_events/3` on agents and graphs
honors `stream_mode:`, live or not: one of the modes
`BeamWeaver.Stream.event_mode/1` returns, or a list of them, such as
`[:messages, :tools]`. The other events are never sent, and an `Error` event
always arrives. `:events`, the default, keeps every event; an unknown mode
returns `{:error, %Error{type: :invalid_stream_mode}}`. See
[Streaming](docs/streaming.md#events).

**Your own run ids.** `invoke/3` and `stream_events/3` take `run_id:`, the id
of the run on its events, `runtime.run_id`, checkpoint metadata, traces and
telemetry. Without it the run gets a new UUIDv7; a subgraph run always gets
its own. See [Streaming](docs/streaming.md#events).

**Private keys saved with the thread.** `Graph.private_channel/2` takes
`checkpoint: true`: the key stays out of the run's output, like any private
key, but is saved in checkpoints, so the next run on the thread starts from
its value. See [Private keys](docs/graph_state.md#private-keys).

#### Models and providers

**One set of error types for every provider.** A failed model call's error
type no longer depends on the provider. It follows the HTTP status:
`:invalid_request`, `:authentication`, `:billing_exhausted`,
`:permission_denied`, `:not_found`, `:rate_limit` and `:server_error`, plus
`:connection` for a request that gets no response and `:timeout` for one that
runs past its timeout. `retry_on: :error`, the default of `ToolRetry` and of a
graph node's `retry:`, leaves out an error that says retrying can't help
(`details.retryable: false`), such as an invalid API key. The old types, and
what to match instead, are under Breaking changes. See
[Errors](docs/models.md#errors).

**Decision models, and OpenAI's Decisions API.** OpenAI's Decisions API, in
public beta, is a decision model:
`Models.init_decision_model("openai:gpt-6-luna")` or
`BeamWeaver.OpenAI.decision_model/1` asks predicate, choice and score
questions (`BeamWeaver.OpenAI.Decisions.Question`) about a string, user
messages with text and images, or other data, which goes as JSON text with its
messages' images in place. Answers keep their probabilities, a declined
question gets a `RefusalAnswer`, and `metadata.cost` counts input tokens only,
as the API bills. Questions are checked before the request. `Models.cached/3`
caches these decisions, and GPT-6 Luna's profile has `decision_outputs: true`.
`DecisionModel.choice_question/3` and `yes_no_question/2` build a decision
model's own question, checked as the model would check it, and `choose/4` and
`probability/4` ask it, so code can work with any decision model; TypeSafe's
and OpenAI's models implement them, and `TypeSafeModelRouter` takes any
decision model as its `classifier:` (see Breaking changes). See [Decision
models](docs/models.md#decision-models) and [OpenAI
Decisions](docs/providers/openai.md#decisions).

**Reasoning effort on every provider.** `Models.Profile` has
`reasoning_effort_levels`, the reasoning efforts a model takes, and
`reasoning_effort_default`, the one it uses when a call names none, on every
provider. Claude Opus 4.5 to 4.8, Sonnet 4.6 and Sonnet 5, and Fable 5 and
Mythos 5 got the levels and defaults Anthropic documents. Anthropic models
take `reasoning_effort:`, the standard name of `effort:` (which wins when both
are set), on the model or a call. It sets `output_config.effort`, and on a
model that takes only adaptive thinking, from Claude Opus 4.7 and Sonnet 5 on,
it turns on adaptive thinking with its summary unless `thinking:` is set. An
effort the model's profile doesn't list fails with `:unsupported_model_param`
before the request. See [Reasoning](docs/models.md#reasoning) and [Anthropic
thinking and effort](docs/providers/anthropic.md#thinking-and-effort).

**Changing settings partway through an OpenAI conversation.** OpenAI's
Responses API takes a `configuration_update` block in a message, such as a new
reasoning effort from that message on, and an `additional_tools` block, tools
added partway through, in a system message. They go as input items of their
own, just before the rest of their message, as `mcp_approval_response`,
`tool_search_output` and `apply_patch_call_output` blocks now do too (they
used to go inside the message, which the API refused). `additional_tools` on
another message, or on Chat Completions, is an error. See [OpenAI
reasoning](docs/providers/openai.md#reasoning).

**Built-in provider tools in agents.** An agent offers a provider's built-in
tools next to its own when they are in its model options, as in
`model "openai:gpt-5.4-mini", tools: [BeamWeaver.OpenAI.ToolCalling.web_search()]`.
See [OpenAI built-in tools](docs/providers/openai.md#built-in-tools).

**The same options on every provider.** `init_chat_model/2` takes
`stream: true` on every chat provider, and an agent whose model was created
with it streams that model's replies. Every chat provider takes both
`max_tokens:` and `max_output_tokens:` for the output cap, and Anthropic and
Google take `stop:` for `stop_sequences:`; on OpenAI and xAI Chat Completions
models, `max_output_tokens:`, set on the model or on a call, is sent as
`max_completion_tokens`. OpenAI and Anthropic models take `base_url:`, the API
root, on the model or in `config :beam_weaver, :openai` / `:anthropic`, like
the other providers; the OpenAI default is `https://api.openai.com/v1`, the
Anthropic default `https://api.anthropic.com`. See [Common
options](docs/models.md#common-options) and [Options for every
provider](docs/providers.md#options-for-every-provider).

**New models.** Grok 4.7, `xai:grok-4.7`: a 500,000-token context and
reasoning efforts from `:low` to `:xhigh`. Z.ai models `zai:glm-5.3-flashx`
(images, video and PDFs like GLM-5.3-Flash, efforts `:low`, `:high` and
`:max`), `zai:glm-5.1`, `zai:glm-5`, `zai:glm-4.7` and `zai:glm-4.6` (200K
context, thinking can be turned off with `thinking: %{type: :disabled}`).
GLM-5.1 and the older models return `:unsupported_model_param` for
`reasoning_effort:`, which Z.ai accepts and ignores on them. Each was checked
against the live API. See [xAI models](docs/providers/xai.md#models) and [Z.ai
models](docs/providers/zai.md#models).

**Images, video and PDFs on GLM-5.3.** GLM-5.3-Flash takes image, video and
PDF blocks, by URL or as base64 data (`ContentBlock.video(data: ...)`,
`ContentBlock.file(data: ...)`), also mixed in one message. GLM-5.3-Flash and
GLM-5.3-FlashX take files uploaded with Z.ai's file API by id:
`ContentBlock.file(file_id: id)` (or Z.ai's own
`%{"type" => "file", "file" => %{"file_id" => id}}` part) is sent as Z.ai's
`file` part; it used to return an `:invalid_content_block` error. Both were
checked against the live API. See [Z.ai images, video and
PDFs](docs/providers/zai.md#images-video-and-pdfs).

**Unknown stream errors reported.** A model stream that the provider breaks
off with an error whose code no provider documents still fails as a retryable
server error (status 500), and BeamWeaver now logs a warning the first time
each provider sends each such code: it names the provider and the code (or
says the error had none) and says the error was treated as a retryable server
error, so the code can be reported and classified. The warning never includes
the error's message or body, and a code that looks like a secret is redacted.
It is logged once per provider and code until the application restarts, for up
to 256 codes. See [Errors](docs/models.md#errors).

#### Memory, storage and retrieval

**Tables in a Postgres schema.** `prefix:` on `Checkpoint.Ecto`,
`Memory.Ecto`, `Cache.Ecto`, `VectorStore.EctoPostgres` and
`Indexing.RecordManager.EctoPostgres` reads and writes the tables that
`BeamWeaver.Migrations.up(prefix: ...)` creates in a Postgres schema. Before,
the migration put the tables in the schema but every adapter looked for them
in `public`. `prefix: ""` or `prefix: false` uses no schema, as with the
migration. See [Create the tables](docs/storage.md#create-the-tables).

**Vector stores of any size.** `index: false` on the `:vector_store` migration
creates the table without a vector index, so stores with more than 2,000
dimensions, such as `text-embedding-3-large` at its full 3,072, can be
created. Searches then compare the query with every row. See [The vector store
and pgvector](docs/storage.md#the-vector-store-and-pgvector).

**Memory lifetimes and pruning.** `BeamWeaver.Memory.prune/2` works on
`Memory.Ecto`, with the same `namespace:`, `max_entries:`, `older_than:` and
`max_age_ms:` options as on `Memory.ETS`; it returned
`:unsupported_operation`. `BeamWeaver.Memory.Item` and `SearchItem` have a
`ttl` field: the record's lifetime in minutes, or `nil`. See [Expiry and
cleanup](docs/long_term_memory.md#expiry-and-cleanup).

**Failed documents in indexing results.** `Indexing.Result` has `failed_ids`,
the ids of the documents the vector store or the record manager rejected. See
[Incremental indexing](docs/retrieval.md#incremental-indexing).

#### Tracing and telemetry

**A bounded local trace store.** `config :beam_weaver, :tracing, max_runs:`
bounds the local trace store. It keeps every run in progress and, by default,
the 10,000 runs that finished last; `max_runs: 0` keeps only the runs in
progress, for nodes that only export. `BeamWeaver.Tracing.clear/0` drops every
run from the store; it replaces the undocumented `Tracing.reset/0`. See [Read
a trace](docs/tracing.md#read-a-trace).

**Trace data kept out of requests.** `ChatModel.invoke/3` takes
`trace_metadata:`, a map added to the call's trace run and never sent to the
provider. See [Name and tag a run](docs/tracing.md#name-and-tag-a-run).

**Uploads finish on shutdown.** The WeaveScope export queue takes `shutdown:`,
the milliseconds it keeps uploading when the application stops (default
`120_000`). See [Export to WeaveScope](docs/tracing.md#export-to-weavescope).

**Durations in graph telemetry.** `[:beam_weaver, :graph, :stop]`,
`:interrupt`, `:parent_command`, `:exception` and `:node_stop` carry
`duration` (native time units) and `monotonic_time`; `:start` and
`:node_start` carry `monotonic_time`. `:exception`, `:interrupt` and
`:parent_command` carry `graph` and `run_id` in their metadata. See [Metrics
with telemetry](docs/tracing.md#metrics-with-telemetry).

#### Tools, filesystem and sandboxes

**The exit code of `execute`, for your code.** A command that the `execute`
tool ran comes back as a tool message whose `metadata.exit_code` is its exit
code as an integer, so code using the agent needn't parse the
`[Command failed with exit code 1]` line. The key is left out when the
backend doesn't know the exit code, and a call whose command timed out or
couldn't run has no `exit_code`. A failed command is still a successful call
(`metadata.status` is `"success"`), and a long output moved into a file keeps
the metadata. See [Sandboxes](docs/sandboxes.md#exit-codes).

**The tool's own error text.** Tool error messages from the tool node carry
the tool's own error text in `metadata.error_message`, next to the
model-facing "Tool error: …" content. See [Results and
errors](docs/tools.md#results-and-errors).

**Where a path leads, and a check for your backend.**
`BeamWeaver.Filesystem.canonical_paths/3` and
`BeamWeaver.Sandbox.canonical_paths/3` return, for each path, the path of the
file it reaches with the backend's symlinks followed, as `{:ok, path}` or
`{:error, reason}`. `Filesystem.Permission.allowed?/5` and
`Filesystem.Permission.filter_paths/5` check paths of a backend the way the
file tools do: the path and the file it leads to.
`BeamWeaver.Filesystem.Conformance.check_symlinks/3` checks, from the tests of
a backend you write, that permission rules see through its symlinks. Give it a
new, empty backend and a function that makes a link in the backend's storage:
it writes a secret under `/secrets`, links to it from `/notes`, and, with a
rule that denies `/secrets/**`, returns `:ok`, or `{:error, problems}` with a
sentence for each way the file tools still read, list, search, write or edit
the secret through the links (or for files no rule denies that they refuse). A
wrapper around another backend passes only when it hands `canonical_paths/3`
on. `:dir` checks under a folder, such as a `Composite` route. See [Check that
permissions see your
links](docs/filesystem.md#check-that-permissions-see-your-links).

#### Compaction engine

**Anti-thrash state.** `BeamWeaver.Compaction.Result` has `anti_thrash`: the
request's lane state, rebased to the request's accounting identity and root
turn, to save and to record the activated checkpoint on.
`Compaction.State.for_root_turn/2` starts a new root turn's counters, and
`Compaction.State.record_ineffective/1` records a compaction attempt that
didn't reclaim enough context. See
[Results](docs/compaction_engine.md#results) and [Automatic
compaction](docs/compaction_engine.md#automatic-compaction).

#### Testing

**Whole agent runs without an API key.** `FakeChatModel.tool_call/2`,
`tool_calls/1`, and `final/1` script tool calls and structured answers, so an
agent runs its whole tool loop on `"fake:chat"`. Agents with `stream: true` on
the fake model stream its reply word by word as `Token` and `MessageChunk`
events. A `FakeChatModel` with a multi-entry `responses:` list plays it in
turn order, one entry per model call, and repeats the last entry once the list
runs out; the turn is read from the conversation (each reply carries
`metadata.fake_turn`), so the script also continues across resumed threads.
Before, it always returned the first entry. `responses:` now takes precedence
over `structured_response:`. `FakeEmbeddingModel` (`"fake:embedding"`) is
documented. See [Script the model](docs/testing.md#script-the-model) and [Fake
embeddings](docs/testing.md#fake-embeddings).

### Breaking changes

#### Security

- Host commands start from a minimal environment. `Sandbox.Local`,
  `Filesystem.LocalShell`, `Tools.Shell` and the `ShellTool` middleware no
  longer pass your application's environment, API keys included, to the
  commands they run: commands get `PATH`, `HOME`, `LANG`, the `LC_*`
  variables, `TMPDIR`, `USER` and `SHELL`, plus the variables in `env:`. Pass
  `inherit_env: true` (to `Sandbox.local/1`, `LocalShell.new/1` or the shell
  policy) to give commands the whole environment again. `ShellPolicy` and
  `Sandbox.local/1` take the new `inherit_env:` option, and `Sandbox.local/1`
  also takes `env:`; a `nil` value in `env:` removes that variable. A shell
  `Session` applies this environment, `nil` removals included, to every
  command it runs, not only the first. `LocalShell`'s `inherit_env:` now
  defaults to `false`, and `false` keeps those base variables instead of
  starting from an empty environment. `ShellPolicy`'s `env_allowlist:` is
  gone: it only filtered the policy's own `env:`, so put just the variables
  commands need in `env:`. `ShellPolicy.new/1` now returns an
  `:invalid_shell_policy` error for an option it doesn't know,
  `env_allowlist:` included, instead of dropping it.
- `ShellPolicy` reads a command line the way the shell does and checks every
  command in it that would run, so a rule can no longer be walked around with
  chaining, quoting or a wrapper. Regex allow rules allow a single command
  only, like string rules: a line that chains commands with `;`, `&&`, `||`,
  `|`, `&`, a newline, `(...)`, `$(...)` or backticks is refused unless the
  policy sets the new `allow_compound: true`. Policies whose regexes match
  chained command lines, such as `allow: [~r/.*/]` for a session that runs
  `cd x && make`, need `allow_compound: true`. A command that only changes how
  another runs (`timeout`, `env`, `FOO=1 …`, `sh -c '…'`, `bash -c`, `dash -c`
  and the other POSIX shells, `eval`, `trap`, `command`, `builtin`, `exec`,
  `nohup`, `time`, `nice`, `stdbuf`, `flock`, `chrt`, `ionice`, `taskset`,
  `busybox`) is looked through: the _wrapped_ command must be allowed, and the
  wrapper needs no rule of its own. A command that runs another as a different
  user, on another host, or once per input (`sudo`, `doas`, `setsid`, `ssh`,
  `xargs`, `find -exec`/`-execdir`/`-ok`, `parallel`, `watch`, `script`, and
  project runners such as `poetry run`, `bundle exec`, `npm exec`) needs a
  rule _and_ the command it runs must be allowed. Policies that relied on
  allowing a wrapper (for example `allow: ["sh"]` or `allow: ["env"]` to run
  anything) must now allow the specific commands instead. Deny rules see every
  command at every level, not only the line's start, also with its leading
  variable assignments stripped and its words unquoted, so a `"rm "` rule
  catches `sh -c 'rm x'`, `env rm x`, `FOO=1 rm x`, `\rm x`, `'rm' x` and
  `/bin/rm x`. Prefix matching treats a rule's trailing whitespace as a word
  boundary (so a `"rm "` rule matches `rm\tx`), and a NUL byte counts as a
  command boundary, which a prefix allow rule refuses, so it can't hide a
  second command. The policy reads a line by the POSIX shell grammar, as bash
  and dash do, so a second command can't hide behind a quote inside a comment,
  `$'\''` (one quote to bash, more to dash), a command substitution inside
  double quotes, a here-document body, bash `$'…'` byte escapes or parentheses
  that open a subshell or arithmetic. A line that bash and dash would read
  differently, or that only a full shell parser could read exactly, is refused
  rather than guessed at. Wrappers and scripts are followed up to eight levels
  deep. The new `ShellPolicy.check/2` returns `:ok` or a
  `:shell_command_rejected` error whose message says why a command is refused
  (no allow rule, a deny rule, code the policy can't read, or a line it can't
  read the same way in every shell); `allowed?/2` is `check/2 == :ok`.
- `ShellPolicy` refuses a command that runs code it can't read from the
  command line, even when a rule for the program matches it: inline
  interpreter code (`python -c`, `perl -e`, `ruby -e`, `node -e`, `php -r`,
  `lua -e`, an `awk` program that calls `system()` or pipes, a `sed` script
  with the `e` command or flag, `vim -c`, `emacs --eval`, `make --eval`, git's
  `-c`, and the `git`, `tar`, `rsync`, `scp` and `zip` options that run a
  command); a script read from a file or standard input (`bash script.sh`,
  `source`, a shell or interpreter with no inline script, `… | sh`); a command
  built at run time (`$TOOL args`, `sh -c "$SCRIPT"`, `eval "$(…)"`, a command
  name with a glob or brace expansion, `xargs` or `parallel` handing input to
  a wrapper or interpreter); shells with their own syntax (`zsh`, `fish`,
  `csh`, `pwsh`) and runners the policy can't read into (`strace`, `gdb`,
  `su`, `chroot`, `tmux`, `at`, …); setting a variable that makes programs
  load or run other code (`PATH`, `LD_PRELOAD`, `BASH_ENV`, `PAGER`, `EDITOR`,
  `GIT_*`, …), or any variable to a value with spaces or shell syntax in it
  (glob characters are fine in an assignment before a command, such as
  `DEBUG=* npm test`, which no shell expands, but not unquoted in an argument
  of `env`, `export`, `sudo` or a wrapper, which shells can expand to file
  names); and bash arithmetic that reads a variable (`$((x))`, `let`,
  `[[ $x -eq 1 ]]`), which runs any command substitution stored in it. To
  allow one, add a rule that spells out the part the policy can't read
  (`"python3 -c"`, `"bash scripts/ci.sh"`), or set the new
  `allow_opaque: true` (default `false`) so that ordinary rules allow such
  commands; deny rules can't see inside them either way. A rule that only
  names the program (`allow: ["python3"]`) no longer allows
  `python3 -c '<anything>'`.
- `Agent.Middleware.ShellTool.new/1` requires a `:policy` and raises
  `ArgumentError` without one; it used to allow every command.
  `Tools.Shell.new/1` raises `ArgumentError` instead of `KeyError` without
  one, and `BeamWeaver.Tools.Shell` checks the policy itself before it hands a
  command to any executor, so a custom `:executor` that trusts what it is
  given can no longer run a command the policy rejects. A shell `Session`
  refuses to start with a custom `:executor`
  (`:shell_session_executor_unsupported`) instead of ignoring it and running
  commands on the host. A session is a persistent host shell: use the one-shot
  `BeamWeaver.Tools.Shell` for a custom executor, or a `BeamWeaver.Sandbox`
  for container execution.
- `TextSplitter.split_url/3` could fetch any URL, so a URL from a user or a
  model could reach internal services or a cloud metadata endpoint
  (server-side request forgery). It now fetches through `Transport.Safe` with
  a `BeamWeaver.Transport.URLPolicy` instead of `:httpc` with none. By default
  it accepts only `https` URLs to public addresses, and refuses private,
  loopback, link-local and cloud metadata addresses, also when a host name
  resolves to one or a redirect points to one, with
  `{:error, %Core.Error{type: :unsafe_url}}`. It connects to the address it
  checked, follows only redirects that pass the same policy, and stops at 5 MB
  and 15 seconds. The new `url_policy:` option takes `URLPolicy` options as a
  keyword list (such as `allowed_hosts:` or `follow_redirects?: false`) or a
  policy struct; to fetch an `http` or internal URL, pass the policy that
  allows it, such as
  `url_policy: [schemes: ["http", "https"], allowed_hosts: ["wiki.internal"], allow_private?: true]`.
  A custom `fetcher:` only gets URLs that pass the policy's checks that need
  no DNS lookup.
- An `interrupt_on` rule map always turns human review on for its tool, and
  `allowed_decisions` defaults to all four decisions. Before, a rule map
  without `allowed_decisions` turned review off, so the tool ran without
  approval. To skip review for a tool, map it to `false`. A rule that can't be
  read (an empty `allowed_decisions`, an unknown decision, a value that isn't
  `true`, `false` or a map of rules, or an `interrupt_on` that isn't a map) is
  an `:invalid_agent` error from `BeamWeaver.Agent.build/1` and agent modules
  instead of being ignored; `HumanInTheLoop.new/1` called directly raises
  `ArgumentError`.
- `Filesystem.Permission` rules see a path as the backends read it. They
  matched the path as the model wrote it, while the backends read it after
  removing `.` segments and repeated slashes, so `/./secrets/key.txt` passed a
  `deny` rule for `/secrets/**` and was read; on a disk that ignores case,
  such as macOS's, so was `/SECRETS/key.txt`. Patterns ending in `/**` with a
  wildcard or braces before it, such as `/**/secrets/**`, `/*/secrets/**` or
  `/{secrets,keys}/**`, denied nothing, and `**/` needed at least one
  directory, so a rule for `/**/*.env` missed a top-level `/prod.env`. Now any
  pattern ending in `/**` covers its folder and everything in it, `**/`
  matches zero or more directories, and deny rules ignore case and Unicode
  normalization (allow rules still match exactly). With rules for an
  operation, a path that isn't a plain absolute path (relative, or with `..`,
  `~` or `\`) is denied; pass absolute paths. A deny rule now also denies
  other spellings of its paths on backends that tell case apart, such as
  `Filesystem.State`; to let one through, put an allow rule for it before the
  deny rule.
- `Filesystem.Permission` rules see through symlinks. They matched only the
  path the model wrote, so a symlink inside a `Filesystem.Local`,
  `Filesystem.LocalShell` or `Sandbox.local/1` directory gave a denied file a
  second, allowed path: with a `deny` rule for `/secrets/**` and a link
  `/notes/key.txt` to `/secrets/key.txt`, `read_file("/notes/key.txt")`
  returned the secret, `ls`, `glob` and `grep` listed and searched it from an
  allowed folder, and `write_file` and `edit_file` reached a denied folder
  through a linked one. The file tools now check a path both as written and as
  the file it leads to, and both must be allowed: for `ls`, `read_file`,
  `write_file`, `edit_file`, `glob` and `grep`, and for every entry that `ls`,
  `glob` and `grep` return, which they leave out when its file is denied. A
  new file is checked as the file it would become, so new files in allowed
  folders work as before. With rules for an operation, a path the backend
  can't resolve, such as a broken link, or on `Sandbox.Docker` a link that
  leads out of the workspace, is denied. `Sandbox.Docker` paths written as
  container paths, such as `/workspace/secrets/key.txt`, are also checked as
  the sandbox path they reach (`/secrets/key.txt`), which a rule for
  `/secrets/**` missed. Backends report where a path leads with the new
  optional callback `canonical_paths/3` of `BeamWeaver.Filesystem` and
  `BeamWeaver.Sandbox`. `Local`, `LocalShell`, `Composite` (in the route's
  backend, keeping the route's prefix), `Filesystem.Sandbox`, `Sandbox.Local`
  and `Sandbox.Docker` implement it; `State`, `Store` and backends without it
  are taken to have no links. A backend or sandbox adapter that wraps another
  one must pass `canonical_paths/3` on to it, as the wrappers in the
  Filesystem and Sandboxes guides do, or the rules won't see the inner
  backend's links. Hard links, and links that another process changes between
  the check and the call, are not covered.
- `glob` and `grep` on `Filesystem.Local` and `Filesystem.LocalShell` search
  only inside their directory. A pattern, or a `grep` `glob:`, with `..`, such
  as `"../*.txt"`, matched the files next to the directory, and a symlink
  inside it that points outside was followed, so the `grep` tool returned the
  lines of those files and `glob` their host paths. A pattern with `..`, also
  one spelled with `\` escapes such as `.\./*`, or with `~` now returns the
  error `"invalid_pattern"`, even when it would stay inside; write the pattern
  from the folder you search, or pass that folder as `path:`. `ls`, `glob` and
  `grep` list only paths the file tools can open, so they leave out symlinks
  that point outside the directory, paths through them (even ones that lead
  back in, which `read_file` now refuses with `"invalid_path"` too), and names
  with `~`. `Sandbox.local/1` directories refuse paths through such symlinks
  the same way; their `read`, `grep` and `download_files` returned the outside
  file, and `edit` and `upload_files` changed it. All three backends follow
  symlinks the way the OS does, also through a `..` after a link:
  `notes/k -> ../x/up/../outside.txt`, with `x/up -> ..`, leads out of the
  directory, though read as text its target names `x/outside.txt`, and is
  refused with `"invalid_path"`. `Filesystem.Local` and
  `Filesystem.LocalShell` read the file the OS opens for such a link, not the
  file its target names as text.
- `Sandbox.Local` no longer reads a file through a full host path that points
  inside its root (`<root>/secrets/key.txt`), which slipped past a
  `Filesystem.Permission` deny rule for `/secrets/**`. Such a path is taken
  literally as the sandbox path `/<root>/secrets/...`, which resolves under
  the root and does not exist, so the path the sandbox reads is the one the
  rules check. Pass sandbox-absolute paths (`/secrets/key.txt`).
- `PII` checks the text blocks of multimodal messages and every message a
  model call adds. It read only plain-string content and tool-call arguments,
  so it left personal data in the text blocks of messages with list content,
  in user input, tool results and model output alike. With
  `apply_to_output: true` it edited only the last assistant message, after the
  model's reply was saved: the checkpoint written after the model call held
  the raw reply, and the failed answer that `StructuredOutputRetry` keeps
  stayed in the thread unredacted. Output rules now edit every message a model
  call adds, and the failed answer, before they are saved, and
  `PII.stream_transform/1` also redacts the text blocks and tool-call
  arguments of a whole `Message` event. `PII` has no `after_model/3` hook:
  output rules run in its `wrap_model_call/3`, so they edit the reply before
  any `after_model/3` hook sees it, and a `:block` rule listed after
  `ModelFallback` makes it try the next model. Call `wrap_model_call/3` to
  test an output rule.
- `ModelFallback` calls a fallback with the fallback's own key and connection
  settings. It called it with the agent model's call options, `api_key:`,
  `base_url:`, `endpoint:` and `transport:` included, and those override a
  model's own: the Claude fallback of an agent on an OpenAI model was sent the
  OpenAI key, to `api.anthropic.com`. A fallback now gets only the agent's
  model options that its profile takes (one it doesn't take, such as
  `reasoning_effort:` for Claude, would fail the call with
  `:unsupported_model_param`), and a provider's built-in tools in `tools:`
  reach only a model of the same kind. `TypeSafeModelRouter` passes options to
  the model it chooses the same way, and no longer passes it the agent's
  `extra_body:`. A fallback or chosen model that relied on the key in the
  agent's model options needs its own: configure the provider's key, or pass a
  model value with
  `init_chat_model!("anthropic:claude-haiku-4-5", api_key: ...)`.
- The warnings a model call emits through telemetry no longer carry the call's
  `metadata:`, which can hold a user id.
  `[:beam_weaver, :models, :param_warning]` (a call with `param_policy: :warn`
  that sends a parameter the model's profile doesn't list) carries the
  provider, the model and the parameter names, and
  `[:beam_weaver, :provider, :unsupported_feature]` (a call with
  `unsupported: :warn` that asks for a feature the model lacks) the provider,
  the model and the feature names. Both used to add the call's `metadata` map
  under a `metadata` key; a handler that read it gets no such key now.
  `BeamWeaver.Models.ParamPolicy.validate/4` no longer takes a `:metadata`
  option.

#### Agents

- `BeamWeaver.Agent.build/1` returns an `:invalid_agent` error that names any
  option it doesn't know, such as `response_schema:` (use `response_format:`),
  instead of ignoring it. The undocumented aliases `backend:`, `permissions:`
  and `overflow_clip:` are gone: use `filesystem:`, `filesystem_permissions:`
  and `overflow_recovery:`. An invalid tool or middleware is an error from
  `build/1` instead of an exception, and so is an option that a middleware or
  capability constructor rejects, also from an agent module's call:
  `:invalid_middleware` for a `middleware` entry, such as
  `middleware: [ShellTool]` without a `:policy` or `DynamicPrompt` without
  `:prompt`, and `:invalid_agent` for capability settings, such as
  `compact_conversation: [trigger: ...]` or an `interrupt_on` rule that can't
  be read. They used to raise the constructor's `ArgumentError` or `KeyError`;
  match on the error instead of rescuing.
- A `model` that is neither a `"provider:model"` string nor a chat model
  struct, such as `{"fake:chat", opts}` or a function, returns an
  `:invalid_agent_model` error, and model options that aren't a keyword list,
  such as `model_opts: %{api_key: key}`, an `:invalid_agent` error; neither
  shows the value (see Security). A model string that can't be initialized
  returns its error instead of failing later.
- With the tool strategy, an answer that calls no tool at all (from a model
  that ignores the forced tool call, or can't be forced, such as Kimi with
  thinking on) counts as a failing answer, with the new error type
  `:missing_structured_output`. The model gets the error as a user message and
  answers again, up to `max_retries` times; then the run fails with the error.
  Before, an agent without other tools returned `{:ok, state}` without
  `structured_response`, and the structured-response call after a tool loop
  called the model again on every step until `:recursion_limit`.
  `StructuredOutputRetry` retries `:missing_structured_output` by default.
- An agent or graph module that creates an in-memory saver, store or cache in
  a declaration doesn't compile, such as
  `checkpointer BeamWeaver.Checkpoint.ETS.new()`, `store Memory.ETS.new()`
  through an alias, `cache BeamWeaver.Cache.ETS.new()`, or one inside another
  declaration, as in
  `filesystem BeamWeaver.Filesystem.Store.new(store: BeamWeaver.Memory.ETS.new())`.
  Declarations are evaluated on every call, so every call got a new, empty
  table: a second `invoke/2` on a thread started over, `get_state/1` returned
  `:error`, and every call left ETS tables behind in the calling process. The
  `CompileError` says what to do instead: create the saver, store or cache
  once, in your supervision tree or a test's `setup`, and pass it per call
  with `checkpointer:`, `store:` or `cache:`; or declare a function that
  returns one created once, such as
  `checkpointer MyApp.Storage.checkpointer()`; or use `Checkpoint.Ecto`,
  `Memory.Ecto` or `Cache.Ecto`. Code inside an anonymous function in a
  declaration, which runs only when it is called, is not affected.
- `BeamWeaver.Agent.build/1` returns an `:invalid_tool` error for a `tools`
  entry that isn't a tool, such as a tool's name; it raised
  `FunctionClauseError`. It returns an `:invalid_agent` error for a
  `response_format` that isn't a schema module, a JSON schema map or a
  `StructuredOutput` strategy, or a module that declares no schema; it raised,
  or asked the model for an empty object. Agent modules check the same on
  their first call. Declare the schema with `use BeamWeaver.Schema` or
  `json_schema/0`.
- `response_schema` raises `ArgumentError` for a module that declares no
  schema or doesn't exist, instead of asking the model for an empty object.
- A run ends on its tools' results only when every call of the batch ran a
  tool with `return_direct true`. When the model also called a tool that
  doesn't return directly, it gets all the results and goes on; one
  return-direct result used to end the run.
- Removed all `async_*` twins (`ChatModel.async_invoke/3`,
  `Compiled.async_invoke/3`, `Memory.async_put/5`, `VectorStore.async_*`,
  `Checkpoint.async_*`, and the rest — 164 functions) and
  `BeamWeaver.Core.Async`. Run calls concurrently with `Task`, or with
  `BeamWeaver.Tracing.async/2` to keep the trace context.
  `MessagesTransformer.process_many/3` and its no-op `:async?` option went
  with them; call `MessagesTransformer.process_many(transformer, events)`.
- Removed `BeamWeaver.Runtime.Agent`, `BeamWeaver.DispatchHook`,
  `BeamWeaver.ProcessRegistry`, `BeamWeaver.Agent.Server`, and the generated
  `start_link/1`/`child_spec/1` on agent modules. Call `MyAgent.invoke/2`
  directly, and run agents in the background under your own `Task.Supervisor`,
  as Going to Production shows.
- Removed `Core.AgentSchema` and `Core.ChatSession`.
- `BeamWeaver.Agent.get_state/2` no longer takes a bare config map; pass
  `config: config`.
- Removed the `debug` declaration and `BeamWeaver.Agent.build/1` option, which
  only marked introspection data; watch a run with streaming or tracing.
- Removed the `tool_timeout` model option; declare `tool_timeout` instead.
  Passing it as a model option returns an `:invalid_agent` error.

#### Middleware

- `CompactConversation` no longer adds a section about the
  `compact_conversation` tool to the system prompt by default; the tool's
  description says when to use it. `system_prompt:` still adds a section of
  your own.
- The automatic summarization that the `compact_conversation` declaration
  turns on, for the agent and its subagents, summarizes all the old messages,
  as the tool does. Set `summarization: [trim_tokens_to_summarize: n]` to read
  only the newest `n` tokens of them. Before, it read the newest 4,000 tokens
  only, so the start of a long thread, often the original task, was left out
  of the summary. `Summarization` declared on its own keeps 4,000.
- The summary the `compact_conversation` tool writes ends with a line naming
  the file the messages it replaces were saved to ("The messages this
  summary replaces were saved in full to /conversation_history/<id>.md."), so
  the model can read them back. Before, the path was only in the message's
  metadata, which the model never sees. Match the start of the summary text
  instead of all of it.
- A middleware hook's update is written as returned, through each key's
  reducer, even when a value equals the current one. Return only the keys you
  change: returning the whole state now fails with `:invalid_update`, because
  `remaining_steps` is read-only.
- `Agent.ModelRequest.new/1`, `ModelRequest.override/2`, and
  `ToolCallRequest.override/2` take keyword lists and raise `KeyError` for
  unknown fields instead of ignoring them; string field names are no longer
  accepted. `ModelRequest` defaults `state` to `%{}` and `messages` to `[]`.
- `ModelCallLimit` and `ToolCallLimit` have no default `thread_limit` (it was
  10, so every agent with them stopped after 10 calls): set `run_limit`,
  `thread_limit`, or both, and add `run_limit: 10` to keep the old cap.
  `ToolCallLimit.new(run_limit: 20)` no longer raises.
- The `compact_conversation` settings configure only the tool (`model`,
  `minimum_messages`, `keep_messages`, …), and `CompactConversation.new/1`
  raises `ArgumentError` for other options. Before, `trigger:` and `keep:` in
  the same list configured the automatic summarization; move them into
  `summarization: [trigger: …, keep: …]`.
- `Summarization` takes `{:fraction, f}` of `max_input_tokens:` instead of the
  summary model's context window. A fraction without `max_input_tokens:`
  raises `ArgumentError`; pass the agent model's window.
- `OverflowRecovery`'s `keep:` defaults to `{:tokens, 5_000}`, the threshold
  the old default `{:messages, 8}` stood for, and takes only `{:tokens, n}` or
  `{:fraction, f}`; `{:messages, n}` raises `ArgumentError`.
- `PII.stream_transform/1` returns a `{fun, state}` pair, and
  `MessagesTransformer`'s `pre_projection:` accepts such pairs alongside unary
  functions. The PII stream buffer no longer lives in the process dictionary.
- `PII` rules edit only the text of messages (string content, or the `text` of
  each content block). An output rule no longer edits the arguments of the
  reply's tool calls, so a tool gets the values the model gave it;
  `PII.stream_transform/1` still edits them in what a stream shows. To keep
  personal data out of a tool, check its arguments in the tool or in a
  `wrap_tool_call/3` middleware.
- `ModelRetry` and `ToolRetry` apply `on_failure` only when the retries run
  out. An error their `retry_on` doesn't cover, such as a bad API key, comes
  back as it is: from `ModelRetry` as `{:error, error}`, so a `ModelFallback`
  listed before it still gets it, and from `ToolRetry` as the tool returned
  it. With `on_failure: :continue` or a function, such an error used to become
  the answer ("Model call failed after 1 attempt ...").
- `retry_on: :error`, the default of `ToolRetry` and of a graph node's
  `retry:`, leaves out an error that says retrying can't help
  (`details.retryable: false`), such as a provider's invalid API key; it used
  to retry every `%Error{}`. To retry such an error anyway, name its type
  (`retry_on: [:authentication]`) or use `retry_on: :all`.
- `TypeSafeModelRouter` takes any decision model as `classifier:`, also as a
  `"provider:model"` string such as `"openai:gpt-6-luna"`, and checks its
  question when it's built. A refusal or a missing answer keeps the agent's
  model with the reason `"refused"`, and an invalid response is a
  `"classifier_error"`: match those instead of
  `"invalid_classifier_response"`, which is gone. Its default `instructions`
  are one string rather than a map, since OpenAI's questions take only
  strings, and the struct keeps the built question in `question` instead of an
  `instructions` field. The classifier gets the message's text, a placeholder
  such as `[image omitted]` for other content, and the images too when its
  profile takes images; when the provider refuses a request with images (HTTP
  400 or 413), the router asks again as text only.
- Removed two-argument middleware hooks. Every hook takes the middleware
  first: `before_model(middleware, state, runtime)`,
  `wrap_model_call(middleware, request, handler)`, and so on; module
  middleware receives its module and ignores it.
- `@behaviour BeamWeaver.Agent.Middleware` on its own no longer makes a
  middleware. Middleware modules call `use BeamWeaver.Agent.Middleware`, which
  supplies overridable `name/1`, `state_schema/1`, `tools/1`, and the other
  defaults; agents reject modules that do not (`:invalid_middleware`).
- Removed the `can_jump_to/2` and `tool_node_required?/1` middleware
  callbacks, and the functions of the same names in
  `BeamWeaver.Agent.Middleware`. Nothing consulted `can_jump_to/2`: a hook
  jumps by returning `{:jump, target, update}`. Every agent now has a tools
  node, so middleware no longer asks for one. Delete both callbacks from your
  middleware; with `@impl true` they no longer compile without a warning.
- Removed string kinds in `Summarization` `trigger:`/`keep:`
  (`{"messages", 10}`); use atoms.
- Removed the `Agent.Middleware.Exclusion` helpers, which nothing called.
  `CapabilityProfile.excluded_middleware` stays data that your own code reads.

#### Subagents and deep agents

- `Subagents` adds nothing to the system prompt by default. Pass
  `system_prompt:` to `Agent.Middleware.Subagents` for a section of your own;
  the list of subagents follows your text. The `task` tool's description is a
  short set of usage notes with the list of subagents, instead of about 6,900
  characters of worked examples; `task_description:` still replaces it.
- The general-purpose subagent, and any subagent with
  `base_middleware: [:deepagents]`, no longer gets a task list
  (`write_todos`). Add `Agent.Middleware.TodoList` to its `base_middleware:`
  or its `middleware` to give it one.
- `AsyncSubagents` adds nothing to the system prompt by default; the tool
  descriptions carry the guidance. `start_async_task` tells the model to give
  the user the full task id and stop, and to check on the task only when the
  user asks, never in a loop. Pass `system_prompt:` to `AsyncSubagents.new/1`,
  listed in `middleware`, to add a section of your own; the list of async
  subagents follows your text. Before, every agent with async subagents got an
  "Async subagents" section with that guidance.
- An async subagent needs a `client:` or a `url:`: an agent with one that
  has neither fails to build with `:invalid_agent` (`AsyncSubagents.new/1`
  raises `ArgumentError`). An `%AsyncSpec{}` written as a struct with a
  `url:` now gets `Agent.Protocol.ReqClient`, as one built with
  `AsyncSpec.new/1` does. Before, a subagent without either was accepted:
  `start_async_task` made up an id and the task stayed `"running"` forever,
  and a struct with a `url:` never called its server.
- `subagent MyApp.Module` runs the module as it declares itself: the options
  after `model`, `filesystem`, `skills`, `memory`, its own `subagents`,
  `recursion_limit`, `checkpointer`, `tool_timeout`, `step_timeout`,
  `run_timeout`, `capability_profile` and every other declaration. Before,
  only a few fields were read, so a child with
  `model "fake:chat", responses: [...]` answered `""`, and its skills, files
  and memory needed `base_middleware:`. Pass `skills: nil` (or another option)
  on the `subagent` line to leave a declaration out.
- Subagents use the run's checkpointer and store, including a per-call
  `checkpointer:`, and save their checkpoints in the parent's thread under a
  namespace of their own; a subagent with a checkpointer of its own saves in a
  thread named after the parent run's `run_id` when the parent runs without a
  thread. `Agent.Middleware.Subagents.new/1` no longer takes `checkpointer:`;
  pass the checkpointer to the parent run. A parent whose subagents, at any
  depth, review tool calls now fails with `:missing_checkpointer` before it
  starts, instead of every `task` call failing. Pass `checkpointer:` and a
  thread id, or turn that subagent's review off with `interrupt_on: false`.
- `Agent.Subagent.Spec.new/1` and `subagent` lines raise `ArgumentError` for
  unknown options instead of ignoring them, and the unused `todo_list` field
  is gone. `Spec.from_agent_module/2` raises for a module without a model; run
  a graph module as a `%BeamWeaver.Agent.Subagent.Compiled{}`.
- The async subagent tools write only the tasks they change, and the
  middleware merges those writes, so parallel task tool calls no longer fail
  on the second write or undo each other (cancelling one task and updating
  another in the same turn keeps both). Each tool writes only the task it
  changed, and `list_async_tasks` only the tasks it refreshed, so a tool
  called directly returns
  `%Command{update: %{async_tasks: %{task_id => task}}}`; read the whole map
  from the agent's state.
- Subagents are checked when the agent is built: `BeamWeaver.Agent.build/1`
  checks each one as a `task` call would build it, without building its graph,
  and returns `{:error, %Core.Error{type: :invalid_subagent}}` naming the
  subagent and the problem, such as an unknown option, a `middleware` entry
  that isn't middleware, a tool that isn't one, a model that can't be
  resolved, a response format without a schema, two middleware of the same
  name that hook into the same step
  (`subagent "worker": graph contains duplicate declarations: model_call_limit.before_model, ...`),
  or a problem of its own subagents
  (`subagent "researcher": subagent "fact_checker": ...`). An agent module
  checks its subagents the same way on its first call, once per version of the
  module: `invoke/2`, `stream_events/2`, `resume/2` and
  `BeamWeaver.Agent.compiled_graph/2` return the error, and `graph/0` raises
  it. Before, such a subagent failed each `task` call with a `Subagent error:`
  tool message. Subagents are still built only when a `task` call runs them.
  The problems `Agent.Middleware.Subagents.new/1` raises `ArgumentError` for,
  such as a duplicate name or an invalid `capture_output`, are returned the
  same way by `build/1` and module calls, and every message names the subagent
  (`subagent "worker": invalid capture_output "worker_output"`).
- Removed the standalone `BeamWeaver.Todo` model.
- Removed the `debug` field of `Agent.Subagent.Spec`. `build/1` no longer
  takes `debug:`, so a subagent spec with it failed every `task` call;
  `Spec.new/1` now raises for it like any unknown option. Remove it.

#### Human review, checkpoints and resuming

- A new message to a thread paused on a tool-call review, its own or a
  subagent's, no longer leaves the review pending: `invoke/3` and
  `stream_events/3` answer the waiting calls as not run and return the
  model's reply instead of `{:interrupted, interrupt}`, and `get_state/2`
  lists no interrupt for it. A `resume_review/3` sent for that review
  afterwards answers only a review pending then; on a thread with none it
  changes nothing and returns the thread's state. A decision sent after
  `update_state/4` added a message to the thread isn't applied either.
  Before, the review paused again and a later decision ran the call. Resume a
  review before sending a new message when its decision should count.
- An `:edit` decision leaves the model's call in its message and runs the
  reviewer's call in its place, which may name another tool. The result starts
  with a note that a reviewer replaced the call, followed by the call that
  ran; `HumanInTheLoop`'s `edit_notice:` words the note, and `nil` leaves it
  out. The message used to carry the edited call: read the call that ran from
  the decision or the result.
- A `:reject` decision's tool result says the user rejected the call: "User
  rejected the tool call for `issue_refund` with reason: …", or, without a
  `message`, that the tool was not executed and the model should not retry it
  unless the user asks. It used to be the `message` alone, or the rejection
  without the advice.
- `get_state/2` `interrupts` and a run's `interrupt.interrupts` list each
  interrupt of a paused subgraph, instead of one record for the subgraph's
  pause with the others nested inside it. Answer them with a map from their
  ids, as for parallel pauses
  (`Map.new(interrupt.interrupts, &{&1.id, answer})`).
- `bulk_update_state/4` without `as_node:` on a thread whose last step ran
  several routing nodes fails with `:ambiguous_state_update`, as
  `update_state/4` does; pass `as_node:`.
- Removed strict-resume checkpoints: `Checkpoint.stage_resume/3`,
  `continue_staged/2`, `verify_resume_receipt/2`, and
  `Checkpoint.ResumeDelivery`.
- Removed `Checkpoint.Utils`.

#### Graphs

- A step in which one task fails and another pauses returns the error,
  whichever finishes first; the paused task stays pending, as `get_state/1`'s
  `interrupts` shows. It used to return the pause when the paused task came
  first in the step. Resume the thread once you have dealt with the error.
- `ToolNode` answers a `tool_call_with_context` input with
  `%{messages: [...]}`, as it does a state, instead of a list of messages, and
  runs such a call in the step's state when the input has no `state`. It takes
  the tool set it may run from that state, for a raw list of calls too. Read
  the messages from the map's messages key.
- Graph nodes, `ToolNode` tools and the runs of
  `Compiled.batch_as_completed/3` no longer stop after 5 seconds by default:
  they run until they finish unless you set `timeout:`. The old default cut
  off most nodes that call a model or an agent. `BeamWeaver.ExecutionPolicy`'s
  `timeout` defaults to `:infinity` too, so a node given
  `timeout: [max_concurrency: 2]`, or an `ExecutionPolicy` without a
  `timeout`, no longer stops after 5 seconds either. Pass `timeout: 5_000` to
  keep the old limit (in an agent, declare `tool_timeout` for its tools);
  `step_timeout:` and `run_timeout:` still bound a whole step or run.
- `Graph.add_node/4` rejects options it doesn't take: a typo such as
  `retry_policy:` for `retry:` makes `Graph.compile/2` return an
  `:invalid_graph` error naming the node and the option, instead of building
  the node without it. A node whose options are invalid in any way (an invalid
  `retry:` or `timeout:`, a module that isn't a node) fails `compile/2` the
  same way; such nodes used to compile and fail only when they ran. The
  error's message is "graph contains invalid nodes" (it was "graph contains
  invalid node callables"), and each entry in `details.invalid` has the node,
  its callable and the error.
- A node that returns `{:error, reason}` fails: its `retry:` and
  `error_handler:` apply, and the run returns
  `{:error, %BeamWeaver.Core.Error{type: :node_error}}` with a string reason
  as the message (any other reason is in `details.reason`, inspected; a
  `%BeamWeaver.Core.Error{}` reason is returned as it is). Before, the tuple
  was stored in the state under `:value`. An error handler that returns
  `{:error, reason}` fails the node the same way.
- `EphemeralValue` keys, and `Topic` keys without `accumulate: true`, last one
  step: the next step's nodes read them, then they are cleared unless written
  again. Before, they kept their value for the rest of the run. At the end of
  each step, every channel that holds a value but got no write now receives
  `update(channel, [])`.
- The message reducers (`Graph.Messages.add_messages/2`, `delta_reducer/2`,
  `normalize/1`) accept what `BeamWeaver.Core.Message.from/1` accepts and
  reject the roles `"human"` and `"ai"`; use `"user"` and `"assistant"`. A
  `"developer"` message becomes a system message, as with `Message.from/1`.
- `max_runs:` on a guarded edge counts the times one run takes the edge. A new
  run on a thread counts from zero, and a run that continues where the thread
  stopped (`resume/3`, `invoke/3` with an empty input after a failure, or a
  continue after `update_state/4`) keeps its count. Before, the counts were
  saved with the thread, so a loop limit used up in one turn stayed used up
  for every later `invoke/3` on the thread. To limit a loop across a whole
  thread, count the rounds in the state with a reducer and check the count in
  the edge's `when:` function, such as
  `when: fn _update, state -> state.revisions < 3 end`.
- An `Overwrite` written to a `DeltaChannel` key drops the other writes of its
  step, as on a reducer key, live and after a reload. Before, the run kept the
  other writes, and a reload gave a different value depending on the order of
  the writes. A checkpoint saved earlier whose step mixed an `Overwrite` with
  other writes now reads as the `Overwrite` alone.
- Removed the `failure_policy:` graph option. It was never implemented: failed
  super-steps always let siblings finish and persist their writes, which is
  now documented as the behavior.
- Removed the node option aliases `retries:` and `on_error:`; use `retry:` and
  `error_handler:`.
- Removed `Graph.Errors`, `Graph.MessagesReducer`, and `Graph.Schema` (use
  `BeamWeaver.Schema`).
- Removed `DeltaChannel.replay_history/4`. It read only the writes saved as
  pending, for the whole thread whatever checkpoint the config named, and
  missed the writes that checkpoints store with each step, so it returned the
  wrong value. Read a thread's values at a checkpoint with `get_state/2`.

#### Streaming

- `stream_events/3` without `live: true` reads the same stream a live call
  returns, to its end, so both give the same events in the same order. The
  collected list therefore starts and ends with the run's
  `Debug %{type: :producer_start}` and `%{type: :producer_stop}` events
  instead of `Debug %{type: :start, status: :running}` and
  `Done %{result: %{status: ...}}`, and a paused run's `interrupt.events`
  include the `Debug %{type: :interrupt}` event. `Done` now only marks the end
  of a streamed model call: use the
  `{:ok, _}`/`{:interrupted, _}`/`{:error, _}` result for how the run ended.
  `metadata:` is added to every event's envelope, and the `namespace:` option
  is gone.
- In an agent's stream (`stream_events/3`), a model call that fails sends a
  `Debug` event whose payload is `%{type: :model_call_failed, error: error}`
  instead of passing on the provider's `Error` event, so an `Error` event only
  ends a run that fails. A run whose failed model call `ModelRetry` retried or
  `ModelFallback` replaced had an `Error` event in the middle and then
  succeeded, and a run that failed had two `Error` events, the model's and
  then the run's. The tokens a failed call sent stay in the stream: drop them
  when the `Debug` event arrives, as the LiveView example in the Streaming
  guide does (a `stream_mode:` list needs `:debug` to get it). For the same
  reason `Stream.Subgraphs`, `Stream.Lifecycle` and
  `Agent.Subagent.StreamTransformer` no longer mark a subgraph or subagent
  failed when one of its model calls failed and was retried; a subgraph whose
  run fails is `:failed` (see Fixed). `PII.stream_transform/1` emits the text
  it holds back for a failed call before that event.
- `BeamWeaver.Graph.Runtime` no longer has a `collect_stream?` field; check
  `stream_sink` to know whether the run is streamed.

#### Memory, storage and caching

- Both memory stores take the same TTL options: `default_ttl:` (minutes) and
  `refresh_ttl:` (`true` or `false`; the default, `false`, is also what `nil`
  means). `Memory.ETS.new(ttl: %{default_ttl: ..., refresh_on_read: ...})` and
  `ttl_config:` become `Memory.ETS.new(default_ttl: ..., refresh_ttl: ...)`,
  and `Memory.Ecto.new(refresh_on_read?: true)` becomes `refresh_ttl: true`.
  `Memory.ETS` no longer refreshes by default. A refresh starts the record's
  own lifetime again; before, it used the store's `default_ttl` and skipped
  records when the store had none. `Memory.ETS.new/1` and `Memory.Ecto.new/1`
  raise `ArgumentError` for an unknown option, which they used to ignore, and
  for a `refresh_ttl:` that isn't a boolean.
- `Memory.Ecto` needs memory schema version 2, which keeps each record's
  lifetime in a new `ttl_minutes` column (filled in for existing records). Add
  a migration that calls `BeamWeaver.Migrations.up(adapters: [:memory])`;
  `verify_migrated!/1` raises until you do. Version 2 gives each record
  already stored the time from its last write to its expiry as its lifetime,
  which is too long for the records a store with `refresh_on_read?: true`
  read, because reading moved their expiry and not their write time. For such
  a store, pass its `default_ttl:` (minutes) to the `:memory` entry, as in
  `BeamWeaver.Migrations.up(adapters: [{:memory, default_ttl: 60 * 24}])`, so
  no record gets a longer lifetime; a non-positive value raises
  `ArgumentError`.
- `Serialization.Config` keeps the codec's own options, such as
  `:encryption_key`, in `opts`. `Serialization.dump/2` and `load/2` give the
  codec those options and the registry, and no longer the caller's other
  options, so put codec options in `serialization: [...]`.
  `Serialization.Encrypted` reads its options from the options it is given, no
  longer from a nested `serialization:` list.
- Map keys keep their type at any depth when `BeamWeaver.Serialization` saves
  a value, so `Checkpoint.Ecto` gives back what `Checkpoint.ETS` gives: state
  values, pending writes, interrupt values, `Send` updates and metadata, and
  `Cache.Ecto` entries, come back as `%{order: %{id: "A-1001"}}` instead of
  `%{"order" => %{"id" => "A-1001"}}`; so do `Serialization.load/2` and
  `load_value/2`. A JSON object names its atom keys under
  `"__beam_weaver_atom_keys__"` (`true` when every key is an atom), and a map
  with other keys, such as integers or tuples, is saved as a list of entries:
  `%{1 => "a"}` no longer loads as `%{"1" => "a"}`, and a tuple key no longer
  raises `Protocol.UndefinedError`. Loading creates no atoms: a key whose atom
  doesn't exist in the running system comes back as a string. Nor does it
  build a struct the serialization registry doesn't list: data that names
  `__struct__` as a key, among a JSON object's atom keys or as an atom key of
  a map saved as entries, is a `{:error, %Error{type: :serialization_error}}`
  from `Serialization.load/2` and `load_value/2`, and `Checkpoint.Ecto` and
  `Cache.Ecto` fail to read such a row, so an edited checkpoint or cache row
  can't become a `File.Stream` or any other struct (BeamWeaver never saves
  that key). A registered exception struct takes `__exception__` from its
  module, not from the saved data. Checkpoints and cache entries saved by
  earlier versions load as before, with string keys in nested maps. Code that
  read string keys from loaded values, such as
  `tuple.checkpoint["channel_values"]["order"]["id"]`, reads the keys that
  were saved: `tuple.checkpoint["channel_values"][:order][:id]`.
- `BeamWeaver.Memory.batch/2` normalizes and checks every operation's
  namespace and key as `put/5` and `get/3` do, and returns
  `{:error, {:invalid_namespace, message}}` without running any operation when
  one is invalid. A put or delete that fails returns `{:error, error}` in its
  place. Before, records could be written under namespaces such as `["a.b"]`,
  `[]` or `[:users]` that `get/3` couldn't reach, and a failed put returned
  `nil`. `search/3` and `list_namespaces/2` now return the same error for a
  prefix with an empty part or a dot, instead of `[]`.
- `Checkpoint.prune/3` returns
  `{:error, %Error{type: :invalid_prune_strategy}}` for a `strategy:` it
  doesn't know; it ran `:keep_latest`.
- `Checkpoint.delete_for_runs/2` returns
  `{:error, %Error{type: :delta_history_in_use}}` and deletes nothing when a
  later checkpoint of the thread reads `DeltaChannel` history from the runs'
  checkpoints. Before, it deleted them and later runs lost those keys' earlier
  values.

#### Tracing and telemetry

- Removed the supervisor-first `Tracing.async(supervisor, fun)` form; use
  `Tracing.async(fun, supervisor: supervisor)`.

#### Retrieval, prompts and parsers

- Chunks no longer copy their document's `id`. The chunks of a document with
  an id get ids made from it, `"refunds:0"`, `"refunds:1"` and so on, in
  `TextSplitter.split_documents/2`, `transform_documents/3`,
  `create_documents/3`, `split_file/3` and `split_url/3`, and carry the
  document's id as `"parent_id"` in their metadata (a chunk split again keeps
  the one it has); chunks of a document without an id still have none.
  `Indexing.index/3` uses `"parent_id"` as a chunk's source when its metadata
  has no `source_id` or `source`, so `cleanup: :incremental` deletes the
  chunks a shorter version of a document no longer has. Code that looked
  chunks up by their document's id should use the derived ids.
- Chat prompts read a message role as `BeamWeaver.Core.Message.from/1` does:
  `"developer"` (or `:developer`) renders a system message with
  `metadata.openai_role: :developer`, and a role other than `system`, `user`,
  `assistant` and `tool` (atoms or strings), such as `"human"`, `"ai"` or
  `"critic"`, is an `:invalid_role` error from `Prompt.format/3`,
  `format_prompt/3`, `Prompt.to_spec/1` and `Prompt.save/3`, and from
  `Prompt.load/2` and `Prompt.from_spec/2` for a saved template with that
  role. Before, `"human"` and `"ai"` were read as `user` and `assistant`, and
  any other role, `"developer"` included, rendered a user message. Use `:user`
  and `:assistant`.
- `Prompt.few_shot/1` and `Prompt.few_shot_chat/1` raise `ArgumentError` for
  an option they don't take instead of dropping it. `few_shot_chat/1` takes
  `prefix_messages:` and `suffix_messages:`, not `prefix:` and `suffix:`.
- Document prompts receive the document text as `{content}` only.
- Removed the runnable composition functions `Runnable.parallel/1`, `map/1`,
  `each/1`, `generator/2`, `passthrough/0`, `assign/2`, `pick/1`, `branch/1`,
  `router/1`, `with_retry/2`, `with_fallbacks/3`, `bind/2`, `with_config/2`,
  `with_types/2`, `configure/2`, `alternatives/4`, `with_history/2`,
  `with_listeners/2`, `as_tool/2`, `pipe/3`, `get_name/1`,
  `batch_as_completed/3`, `stream_events/3`, `stream_log/3`, runnable
  specs/registry, and runnable graph drawing. `Runnable.invoke/3`, `batch/3`,
  `stream/3`, `transform/3`, `lambda/2`, and `sequence/2` remain. Use Elixir
  functions, `with`, and `Task.async_stream/3` for composition.
- Removed document loaders and blobs (`DocumentLoader`, `DocumentTransformer`,
  `DocumentIndex`, `Blob`, `BlobLoader`, `BlobParser`, `BlobLike`,
  `DocumentLike`), `Indexing.DocumentIndex`, `StructuredQuery`,
  `DocumentCompressor`, `CrossEncoder`, `Core.HTML`, and `Core.Strings`. Load
  sources with plain Elixir into `%Core.Document{}` and pass them to
  `TextSplitter` and `Indexing.index/3`; `Core.Document.from/1` builds
  documents from strings and `:content` maps.
- Removed `Core.Document.lc_namespace/0`, `serializable?/0`,
  `langchain_string/1`, the `type` field, and its `page_content=`
  `String.Chars` impl.
- Removed the text splitter option aliases `is_separator_regex`,
  `max_chunk_size`, `headers_to_split_on`, and `strip_headers`.
- Removed `OutputParser.Spec` (parser serialization to spec maps) and
  `OutputParser.output_schema_for/1`.
- Removed the unused `%BeamWeaver.Indexing{}` struct. `Indexing.index/3`
  returns an `Indexing.Result`.

#### Tools

- `Core.Tool.invoke/3` with plain arguments returns a `%Core.ToolResult{}`
  with `content` and `artifact` for a `response_format :content_and_artifact`
  tool, instead of the content alone, also when the tool returns
  `{:content_and_artifact, content, artifact}`. Read `result.content` for the
  text. A `%Graph.Command{}`, a message, or a list of them comes back as it
  is, so such a tool's command still updates the agent's state.
- When several tool calls of one step return a `%BeamWeaver.Graph.Command{}`,
  `ToolNode` returns a list: one command with all the tool messages, the
  routing and `jump_to`, then each tool's other updates, so every update goes
  through the key's reducer. Two tools that write the same key without a
  reducer now fail the step with `:invalid_update` instead of the last write
  winning; declare a reducer for keys that parallel tools write. Commands for
  the parent graph are still combined into one.
- In an agent, a tool that injects `:state` gets the state as the run returns
  it, and so does its `ToolRuntime.state`: the agent's private keys (such as
  `usage`, `tool_set` and the call-limit counts, and keys that middleware
  declares with `Graph.private_channel/2`) and managed keys (such as
  `remaining_steps`) are left out. A tool that needs one names it with
  `injected :name, {:state, :key}`, which reads any key; the `shell` tool of
  `Agent.Middleware.ShellTool` now reads its session that way.
  `Graph.Nodes.ToolNode.new/2` takes `private_keys:` to leave keys out in a
  graph of your own.
- `@behaviour BeamWeaver.Core.Tool` on its own no longer makes a tool.
  Hand-written tools call `use BeamWeaver.Core.Tool`, which defaults every
  optional callback the module does not define. Tool conversion recognizes
  tools and toolkits by the behaviour they declare instead of probing for
  `name/1` or `tools/1`.
- Removed `Core.Tool.run/3`; use `invoke/3`.
- Removed `Tools.Helpers`.

#### Filesystem and sandboxes

- `glob` and grep's `glob:` read a pattern the same way on every backend: a
  pattern without `/` matches a file's name at any depth below the path
  searched, so `*.py` finds `/src/app/main.py`; one with `/` matches the path
  from there (`src/**/*.py`), and a leading `/` anchors it there, so `/*.py`
  matches only top-level files. `[abc]`, `[a-z]` and `[!a]` or `[^a]` are
  character classes, `{md,txt}` matches either, `\` makes the next character
  literal, and an unclosed `[` or `{` is the error `invalid_pattern`. A
  `Composite` searched from `/` reads a pattern with `/` from `/`, its routes
  included. See [Glob patterns](docs/filesystem.md#glob-patterns). Before,
  `*.py` matched only top-level files in `State`, `Store`, `Local`,
  `LocalShell` and the local sandbox's `glob`, but any depth in its `grep`
  and in Docker's `glob`, and Docker missed `/top.py` for `**/*.py` and
  matched nothing for `/*.py`. `State` and `Store` read classes, `{a,b}` and
  `\` as plain text, and `Local`, `LocalShell` and the local sandbox read
  `[!a]` as "`!` or `a`", the opposite of what it asks for. Permission rules
  keep their wildcards (`*`, `?`, `**`, `{a,b}`).
- `ls`, `glob` and `grep` of a path that doesn't exist return the error
  `file_not_found` on every backend, and `grep` with a file as its `path`
  searches that file. Before, `State`, `Store`, `Local`, `LocalShell` and a
  `Composite` returned an empty list for a missing path (the local sandbox's
  `ls` and Docker's `glob` and `grep` already gave the error, and Docker's
  `ls` gave `find`'s message), and `Local`, `LocalShell` and the local
  sandbox found nothing when `path` was a file.
- `write/4`, and so the `write_file` tool, replaces a file that exists on
  every backend, and the tool's description and the filesystem prompt say
  so. In `State` and `Store` the file keeps its creation time, and text
  written over a binary file is stored as text. Writing over a directory is
  still an error. Before, writing to an existing path returned the error
  `file already exists`.
- When `execute` output is over its limit, `LocalShell`, the local sandbox
  and the Docker sandbox keep its first and last halves, with a line between
  them such as `... [48210 bytes cut] ...`, so the end of a build or test log
  survives; `truncated` is still set. Before, they kept only the first bytes,
  and `LocalShell` and Docker added `... Output truncated at N bytes.`.
- `read_file` returns at most 80,000 characters, cut at a whole line, and a
  page that stops short of the end of the file ends with the lines it shows
  and the offset to read on from, such as `[Showing lines 1-2000. The file
  continues: read again with offset 2000.]`. A single longer line is cut and
  the note says so. Before, a page looked like the whole file, and one long
  line could return megabytes even with `limit: 1`.
- `read_file` returns an image (PNG, JPEG, GIF, WebP) or a PDF as a tool
  message whose content is a short notice and an image or file content block
  with its media type; any other binary file is a short notice with its size.
  Before, every binary file was an `"image"` block with no media type, which
  an agent turned into base64 JSON text in the tool message.
- `ls`, `glob` and `grep` results stop at 80,000 characters, after the last
  whole entry that fits, and end with a note that says how many results they
  show and asks the model to narrow the search with a more specific path or
  pattern. Before, these results were never cut or moved into a file, so a
  search over 20,000 files put 1.5 MB of JSON in the thread.
- `read_file` rejects a negative `offset` and a `limit` below 1, and an
  `offset` past the last line of a file returns an error such as
  `Error: offset 50 is past the end of /notes.md (3 lines)`. Before, negative
  values passed (`Sandbox.Local` read them from the end of the file), and a
  page past the end returned `""` like an empty file.
- `edit` returns the error `"old_string must not be empty"` for an empty
  `old_string` on every backend. Before, `Filesystem.State`, `Store`, `Local`
  and `Sandbox.Local` returned `"string not found"`, and `Sandbox.Docker`
  raised.
- Reading an empty file on `Filesystem.State` or `Filesystem.Store` returns
  `System reminder: File exists but has empty contents`, as the disk and
  sandbox backends do. Before, it returned `""`.
- `Filesystem.State.write/4` and `edit/5` return only the file they changed
  in `files_update`, as `%{path => file_data}`, instead of the whole files
  map. Merge it into the state's files, as the agent's `files` key does; code
  that used it as the whole map now gets that one file.
- `Sandbox.Docker` operations on a sandbox that isn't started return
  `error: "container_not_started"` instead of starting a new container for
  each operation and never removing it. Call `Docker.start!/1` and use the
  sandbox it returns. `remove: true` (the default) now removes the container
  when the process that called `start!/1` exits, and starts it with `--rm`;
  pass `remove: false` to keep it until `Docker.stop/1`.
- `Filesystem.State.upload_files/3` returns an error for every file instead of
  reporting success while storing nothing. Pass State files in the agent's
  input as `files:`, or set them with `Graph.Compiled.update_state/4`.
- Removed the forwarding protocols `Graph.Channel.Dispatch`,
  `Filesystem.Backend`, `Filesystem.ExecutableBackend`, `Sandbox.Backend`, and
  `Indexing.RecordManager.Backend`. `use BeamWeaver.Graph.Channel` (and
  `Filesystem`, `Filesystem.Executable`, `Sandbox`, `Indexing.RecordManager`)
  declares the behaviour, and the facade functions call the struct's module.
  Check an implementation with `Channel.implemented_by?/1`,
  `Filesystem.backend?/1`, `Filesystem.Executable.executable?/1`,
  `Sandbox.sandbox?/1`, or `RecordManager.record_manager?/1`.
- Removed `Filesystem.Utils`, the deprecated `Filesystem.is_directory/0` (use
  `directory_error/0`), and `Filesystem.ls_info/3` and `glob_info/3` (use
  `ls/3` and `glob/3`).

#### Models and providers

- A failed model call's error type is the same for every provider and follows
  the HTTP status: `:invalid_request` (400 and 422), `:authentication` (401,
  and the 400 with which Gemini and xAI refuse a wrong API key),
  `:billing_exhausted` (402), `:permission_denied` (403), `:not_found` (404),
  `:rate_limit` (429) and `:server_error` (every 5xx, which is retryable now,
  not only 500, 502, 503, 504 and 529). A request that gets no response is a
  `:connection` error, and one that runs past its timeout a `:timeout`. They
  were `:http_error` and `:transport_error`, and from DeepSeek, Kimi and Z.ai
  `:authentication_error`, `:rate_limit_error`, `:overloaded_error`,
  `:invalid_request_error` and `:quota_error`: match the new types instead,
  and `:billing_exhausted` for `:quota_error`. A context overflow, an
  exhausted quota and Z.ai's and Kimi's content filters keep their types; any
  other status is still an `:http_error`, and a request the transport refuses,
  such as a cassette mismatch, a `:transport_error`. `Transport.ReqFinch`
  reports a timeout as a `:timeout` `Transport.Error`, no longer
  `:transport_failure`.
- A profile's reasoning efforts are fields, no longer in `extra`: read
  `reasoning_effort_levels` for `extra.reasoning_efforts` and
  `extra.effort_levels`, and `reasoning_effort_default` for
  `extra.default_reasoning_effort` and `extra.default_effort`.
- `init_chat_model/2`, `init_embeddings/2` and `init_decision_model/2` return
  `{:error, %Error{type: :unsupported_model_param}}` for an option the model
  doesn't take, such as a misspelled one or `reasoning_effort:` on Anthropic;
  they used to drop it. Their errors carry the provider in `details.provider`
  for every model. Call options, such as `tools:` or `tool_choice:`, go with
  each call (`ChatModel.invoke/3`) or through `Models.bind_tools/3`; an
  agent's model options may still carry them.
- Every provider checks a call's model parameters against the model profile,
  as Google and the OpenAI-compatible providers did: OpenAI and xAI Responses
  and Anthropic now return `:unsupported_model_param` for a parameter the
  model doesn't list, such as `top_k:` or `stop:`, instead of dropping it.
  `stop:` on xAI reasoning models over Chat Completions returns it too; it
  used to be dropped.
- The `api:` option of OpenAI and xAI returns `:invalid_provider_option` for a
  value other than `:responses` or `:chat_completions`; it used to fall back
  to Responses.
- A missing API key fails before any request with
  `{:error, %Error{type: :missing_api_key, details: %{provider: ..., retryable: false}}}`
  on every provider. It used to send the request without credentials.
  TypeSafe's `:model_authentication` error is now `:missing_api_key`.
  Credentials in an `authorization` (or the provider's key) header in
  `default_headers:` count as a key.
- A failed transport call keeps its cause: the `:transport_error` has the
  transport's error type in `details.reason` (such as `:cassette_mismatch`,
  `:timeout` or `:transport_failure`), with the transport's details, such as
  `details.request` and `details.expected` for a cassette mismatch;
  `details.reason` used to be an inspected string. A `BeamWeaver.Core.Error`
  from a transport is returned unchanged.
- `Core.Messages.Utils`: `messages_to_dict/1` is now `encode/1`,
  `messages_from_dict/1` is `decode/1`, `get_buffer_string/2` is
  `buffer_string/2`, and `convert_to_openai_messages/2` is
  `to_openai_messages/2`, which with `api: :responses` returns one flat list
  of items, an assistant message with tool calls giving its message item and
  one `function_call` item per call. `message_to_dict/1` and
  `convert_to_messages/1` are removed (use `encode/1` and `normalize/1`).
- The `:approximate` token counter and
  `LanguageModel.count_tokens_approximately/1` estimate about four characters
  per token, plus three per message, the same way as
  `Messages.Utils.count_tokens_approximately/2`, instead of counting words.
  This changes `Messages.Utils.trim/2` by default, the `:approximate`
  `ContextEditing` counter, and `count_tokens` of models without a tokenizer,
  such as the fake models; raise budgets that were set in words. `trim/2` with
  `allow_partial: true` also measures the partial message with the counter,
  overhead included, instead of counting words, and leaves the message out
  when not even one word fits.
- `Models.UsageCost` reads pricing maps with atom keys only (as profiles
  define them). Raw provider usage maps may still use string keys.
- `Transport.Safe` no longer uses a `:finch` option you pass: every request
  runs on the isolated pools (see Security). Pass connection settings, such as
  a proxy or `transport_opts` with CA certificates, as `connect_options:`
  instead; a pinned request ignores both, as before, and connects straight to
  the address it checked.
- xAI Responses requests to a reasoning model carry
  `"include": ["reasoning.encrypted_content"]`, added to an `include:` list
  you pass; `extra_body: %{include: [...]}` replaces the list. Replay
  cassettes and fakes that match xAI request bodies exactly need the new
  field; re-record them or add it.
- `use_previous_response_id: true` on OpenAI continues only from a reply
  OpenAI made (`response_metadata.model_provider == "openai"`, as every
  decoded OpenAI reply has), so a DeepSeek Responses reply (after a fallback,
  say), whose id also starts with `resp_`, is no longer sent to OpenAI as
  `previous_response_id`. A reply built by hand with only
  `response_metadata: %{id: "resp_..."}` is sent as a message; add
  `model_provider: "openai"` to it, or pass `previous_response_id:`.
- `OpenAI.ModerationMiddleware` (and `moderate/2`) return the client's error
  when the moderation request fails, such as `:missing_api_key`, `:http_error`
  (with `details.status`) or `:transport_error`, instead of wrapping every
  failure in `:openai_moderation_request_failed` with an inspected reason.
  Match on those types instead.
- Typed streams are made of `BeamWeaver.Stream.Envelope` structs to the end.
  Anthropic's and Gemini's `stream_typed_events/3`, and every client's typed
  stream function (such as `Anthropic.Client.messages_stream_typed_events/3`,
  `OpenAI.Client.responses_stream_typed_events/3` and
  `Google.Client.stream_events/4`), ended a failed stream with a bare
  `%Events.Error{}`. A wrapped model (`Models.bind_tools/3`,
  `with_rate_limiter/2`, `cached/3`) ends its typed stream with an `Error`
  envelope and no `Done` after it; it sent the error as a `Custom` event
  followed by `Done`. Match `%Envelope{event: %Events.Error{}}`.
- A model stream that reports an error partway through fails with the
  provider's HTTP error, the one the same failure gets without streaming (see
  Fixed), such as `:http_error` with `status: 503`; match on those error types
  and on `details.status` or `details.code` instead. A Chat Completions
  (OpenAI, xAI) or Gemini stream with an `error` chunk failed with
  `:response_error`. A Responses API stream (OpenAI, xAI, DeepSeek) that ends
  with `response.failed` fails like one with an `error` event, with the HTTP
  error for the failed response's error code: `server_error` is a retryable
  `:http_error` with `status: 500`, `rate_limit_exceeded` a retryable 429 and
  `invalid_prompt` a 400 that isn't retried, with the failed response in
  `details.body["response"]`. Before, its typed stream ended with a
  `:response_failed` error, and `stream_response/3` returned
  `:response_error`, which `ModelRetry` didn't retry even for a server error.
  A stream that ends with `response.incomplete` still ends with the reply,
  with `status: "incomplete"`, as without streaming. Text streams (`stream/3`)
  and raw lifecycle streams (such as
  `Anthropic.Client.messages_stream_events/3` and
  `OpenAI.Client.responses_stream_events/3`) end with an `Error` event after
  such an error, as they do after a failed HTTP response, instead of ending
  early, ending as if the reply were complete, or passing the provider's error
  event through.
- A Z.ai or DeepSeek reply that the provider ends with a finish reason
  reporting that it couldn't finish it fails the call, with or without
  streaming, with the error the provider gives the same failure. Z.ai's
  `sensitive` (its safety review blocked the reply; Z.ai sends it instead of
  its error 1301) is a `:content_filter` error with `status: 400`, which
  `ModelRetry` doesn't retry. Z.ai's `network_error` (its inference failed)
  and DeepSeek's `insufficient_system_resource` and `aborted` are server
  errors with `status` 500, 503 and 500, which it retries. `details.code` is
  the finish reason. `invoke/3`, `stream_response/3`, `stream_typed_events/3`,
  `stream/3` and streaming agents returned such a reply, cut short or blocked,
  as a complete one with the finish reason as its `status`: handle the error
  instead. Every other finish reason still ends a reply, the way each API
  documents it, including `length`, Z.ai's `model_context_window_exceeded` and
  OpenAI's and DeepSeek's `content_filter` (the reply holds what the filter
  left); check the reply's `status`.
- Anthropic models check `metadata:`, Anthropic's request field, before the
  request. Anthropic's API reference gives it one key, `user_id`, a string of
  at most 512 characters. Another key, a `user_id` that isn't a string of at
  most 512 characters (or `nil`), or a value that isn't a map returns
  `{:error, %Error{type: :unsupported_model_param}}` whose message names the
  key: from `init_chat_model/2` for the model's own `metadata:` (so an agent
  with it fails before its first model call) and from every call. Lengths
  count characters, not bytes. Such metadata used to be sent to Anthropic as
  it was. Send only `user_id`, and put trace data in `trace_metadata:`.
- OpenAI models check `metadata:` against the limits in OpenAI's API
  reference, on Responses and Chat Completions: a map of at most 16 key-value
  pairs, with keys of at most 64 characters and values that are strings of at
  most 512 characters (atom keys and values are sent as strings, and lengths
  count characters, not bytes). Other metadata returns
  `{:error, %Error{type: :unsupported_model_param}}` whose message names the
  key at fault, never a value: from `init_chat_model/2` for the model's own
  `metadata:`, and from every call. Such metadata used to be sent as it was (a
  keyword list failed to encode).
- Moonshot, DeepSeek and Z.ai models refuse `metadata:`, which none of their
  APIs has. A call with it returns
  `{:error, %Error{type: :unsupported_model_param}}`, checked against the
  model's profile and `param_policy:` like any other parameter; it used to be
  dropped without a word. Z.ai's model profiles no longer list `:metadata`, so
  creating a Z.ai model with it no longer suggests passing it on the call, and
  a DeepSeek Responses model created with an option every call refuses, such
  as `metadata:` or `store:`, fails when it is created, with that call's
  error. Put trace data in `trace_metadata:`; for an end-user id, DeepSeek and
  Z.ai take `user_id:` and Moonshot `safety_identifier:`.
- xAI models check `metadata:` when they are created. xAI's Chat Completions
  API has no request metadata, and its Responses API keeps the field only for
  compatibility, so every call with a model's `metadata` failed;
  `init_chat_model/2` now returns that call's error,
  `{:error, %Error{type: :unsupported_model_param}}` with
  `params: [:metadata]`, checked against the model's profile and
  `param_policy:` as calls are. An agent whose xAI model declares `metadata:`
  fails before its first model call. Put trace data in `trace_metadata:`.
- Removed `ChatModel.generate/3`, `generate_prompt/3`, `LLM.generate/3`, and
  `LLM.generate_prompt/3`; use `batch/3`.
- Removed `Provider.ReasoningControl`, which nothing in BeamWeaver used. Pass
  `reasoning_effort:` to the model instead.
- Removed `Core.Error.create_message/2`, `error_codes/0`, `output_parser/2`,
  `context_overflow/2` and `tracer/2`, and the decoding of `lc`/`kwargs`
  message envelopes.
- Removed the `Core.MessageLike`, `Core.ContentBlockLike`, `Tool.SchemaLike`,
  and `ExampleLike` protocols. Use `Core.Message.from/1`,
  `Core.ContentBlock.from/1`, and `Tool.Schema.from/1`.
- Removed the typed message structs `Core.Messages.System`, `User`,
  `Assistant`, `Tool`, `Function`, `Chat`, `ToolChunk`, and `FunctionChunk`,
  and the `Core.Messages.system/2`, `user/2`, `assistant/2`, `tool/2`,
  `function/2`, `chat/3`, and `to_message/1` constructors. Use
  `Core.Message.system/2` and friends.
- Removed the role aliases. Message tuples, maps, prompt templates, prompt
  specs, `Utils.filter/2`, and `trim/2` accept only `"user"`, `"assistant"`,
  `"system"`, `"tool"`, and `"developer"` (or the matching atoms); `"human"`,
  `"ai"`, and `"function"`, the `type` alias for `role`, and
  `additional_kwargs` are no longer read.
- Removed the `"langchain-openai"` message format name; pass
  `format: :openai`.
- Removed the `Provider.EncodeMessage` and `Provider.DecodeMessage` protocols;
  use `Provider.MessageCodec.encode/2` and `decode/2`. With
  `provider: :openai`, `encode/2` returns a list for an assistant message with
  tool calls: its message item and one `function_call` item per call, as the
  Responses API takes them.
- Removed the provider error structs `OpenAI.Error`, `Anthropic.Error`,
  `Google.Error`, `XAI.Error`, `DeepSeek.Error`, `Moonshot.Error`, and
  `ZAI.Error`. Every provider returns `%BeamWeaver.Core.Error{}`, with the
  provider in `details.provider`.
- Removed `Provider.ChatRuntime.Adapter`. Provider chat models implement the
  `Provider.ChatModel` callbacks (`request_body/3`, `send_request/4`,
  `decode_response/2`, `parse_response/3`, `stream_metadata/3`) instead of
  returning a struct of closures.
- Provider client functions no longer accept a keyword list in place of a
  client (`Client.chat_completions([api_key: ...], body)`); build one with
  `Client.new/1`. Per-call options still override `:endpoint`, `:api_key`,
  `:transport`, `:transport_opts`, `:timeout`, and `:headers`, but no longer
  other client fields such as `:default_headers` or `:base_url`. `new/1` takes
  keyword lists only.
- Removed `:model_kwargs`, the model field and option. Use `:extra_body`,
  which every chat model now accepts both as a model field and per call
  (per-call keys win). It is merged into the request body after BeamWeaver's
  own fields, so it overrides them; DeepSeek, Moonshot, and Z.ai keep `model`,
  `messages`, and `stream`, and Anthropic its reserved fields. Before,
  `model_kwargs` was merged first and typed options overrode it.
- Removed `Provider.GenericMessages`, `Provider.HostedTools`, and
  `Models.FunctionEmbeddingModel`.

#### Compaction engine

- `Compaction.State.record_success/2` takes the activated
  `%Compaction.Checkpoint{}` and records its trigger, high-water mark, tokens,
  accounting identity and root turn. It replaces
  `record_success(state, trigger, lane_ordinal, tokens_after)`; you no longer
  need `State.rebase_accounting/2` before it.

### Security

- `Transport.URLPolicy`, which `TextSplitter.split_url/3` and
  `Transport.Safe` use, let through addresses it refuses when they were
  written in some IPv6 forms. IPv4-translated (`::ffff:0:a.b.c.d`) and 6to4
  (`2002::/16`) addresses passed whatever IPv4 address they carry, such as
  `[2002:a9fe:a9fe::]`, which a host with a 6to4 route sends to the metadata
  address 169.254.169.254, and so did the deprecated site-local range
  `fec0::/10`. An IPv6 host with a zone id, such as `http://[fe80::1%25en0]/`,
  was read as the host name `fe80`, let through, and the URL rewritten to
  `http://fe80/`. IPv4-translated and 6to4 addresses are now judged by the
  IPv4 address they carry (a private one needs `allow_private?: true`),
  `fec0::/10` is refused like the other reserved ranges, and a host in
  brackets must be a plain IPv6 address: one with a zone id, or anything else
  in brackets, is refused with `:unsafe_url`.
- `Transport.Safe` requests, which `TextSplitter.split_url/3` makes, no longer
  grow BeamWeaver's connection pools without bound when their URLs come from
  users or models. Pinned requests
  (`pin_resolved?: true`) started a Finch instance, with its processes and
  nine new atoms, for every host, address or timeout they reached, and the
  other Safe requests added a connection pool for every origin to the pool
  provider calls share; both were kept forever and could exhaust processes or
  the atom table. Every Safe request now runs on at most 16 isolated
  connection pools in one BeamWeaver-owned Finch instance, apart from the
  provider pool: one per origin, TLS host name and connection settings. A
  request that needs a new pool closes the least recently used pool with no
  request in flight, or waits for one within its `:total_timeout`, and a pool
  closes after a minute without requests. Change the limits with
  `config :beam_weaver, :transport, max_isolated_pools: 32,
  isolated_pool_idle_timeout: 30_000`. Any `Transport.ReqFinch` request that
  sets `:mint_connect_options` uses the same pools. Safe requests that aren't
  pinned now also stop reading a response as soon as its headers pass
  `:max_response_header_bytes`.
- The tools an agent hides from its model stayed hidden only until the run
  paused. After a human review (`interrupt_on`), an
  `interrupt_before: [:tools]` breakpoint, a pause inside a tool or a crash,
  the continued run could call every tool the agent has, so a call to a tool
  that `exclude_tools`, a capability profile, `ToolSelection` or middleware
  using `ModelRequest.override(tools: ...)` hid from the model ran. The tools
  node now runs only the tools the model was offered on its latest call,
  also in a run that continues from a checkpoint: their names are saved with
  the thread (kept out of the run's result and `get_state/1`). Tools that a
  `ToolSelection` lists under `tools:` also run after a pause now; before,
  they failed with "tool is not registered". A tool that a function or other
  middleware creates on each call isn't saved: after a pause, a call to it
  gets that error, and the model's next call offers it again.
- `Sandbox.Docker.download_files/3` could return files of the host. It copied
  a file out of the container with `docker cp`, which copies a symlink as a
  symlink, and then read the copy on the host, so a symlink made in the
  container, such as a skill's `SKILL.md` pointing to `/home/app/.ssh/id_rsa`,
  returned that host file (skills load their files with `download_files`). It
  now copies the file the symlink leads to inside the container. A directory
  returns the error `"is_directory"` instead of raising, and its temporary
  copy is removed.
- A `PII` output rule (`apply_to_output: true`) edits the text of the
  structured answer of an agent with tools, the extra model call after the
  tool loop, which was saved unedited.
- `inspect/1` no longer prints credentials: the API keys and auth headers of
  Anthropic, Google, Moonshot, Z.ai and xAI models and clients,
  `Provider.HTTPClient`, the WeaveScope exporter config, `Transport.Request`
  and async subagent specs (which now share one redacting `Inspect` impl),
  the `env` values of `Sandbox.Local`, `Filesystem.LocalShell` and
  `ShellPolicy`, the environment of a shell `Session` (the policy's secrets
  and what commands export), also in its crash logs (`format_status/1`), and
  the codec options of `Serialization.Config`, such as `:encryption_key`.
  Agent errors don't show them either: an `:invalid_agent_model` or
  `:invalid_agent` error for a model or model options of the wrong shape,
  such as `model: {"openai:gpt-5.4", api_key: key}` or
  `model_opts: %{api_key: key}`, names the kind of value and its keys
  (`"a map with keys [:api_key]"`), and an error for a middleware's missing
  or unknown option names that option without showing the others.

### Changed

#### Agents

- Every declaration in an agent module is evaluated when the agent runs,
  including the options after `model "..."`, `model_opts`, the `field`
  options in a `context_schema` block and `interrupts`, so they can read
  configuration and call functions such as `self()`. Before, `model_opts`
  with non-literal values stored their syntax tree. `model_opts` is merged
  over the options after `model`, whatever the order of the two lines.
- `context_schema` moves a declared field given under a string key to its
  atom key before tools and middleware see the context. A type that is
  neither built in nor a struct module (such as a misspelled atom) is an
  `:invalid_agent` error instead of a check that every value fails.
- The "Sorry, need more steps to process this request." answer replaces a
  tool call whenever the steps left can't fit the tool round, the next model
  call and the middleware hooks on the way to the end, so a run with
  middleware ends with that answer too instead of a `:recursion_limit` error.
  Without middleware it now also applies when exactly two steps are left,
  where the tools used to run and the run then failed.
- Every agent has a tools node, so a model that calls a tool the agent
  doesn't have gets "Tool error: tool is not registered" back instead of the
  run raising `KeyError`.
- A declared `checkpointer` or `store` whose function returns a new
  `Checkpoint.ETS` saver or `Memory.ETS` store each time logs a warning on the
  agent's first call, naming the module and the declaration.

#### Middleware

- A struct middleware listed as a bare module, `middleware [MyApp.Limit]`, is
  built like `{MyApp.Limit, []}`, so its hooks get the default struct instead
  of the module. Its default `name/1` becomes the last part of the module
  name, as for any struct middleware.
- A `Middleware.Filesystem`, `Skills`, `Memory`, `CompactConversation` or
  `OverflowRecovery` entry listed as a module or `{module, opts}` gets the
  declared `filesystem` as its `backend` (and `Filesystem` the declared
  `filesystem_permissions`) unless its options name others.
- The `ToolSelection` that `exclude_tools` and `tool_descriptions` add runs
  in addition to a `ToolSelection` listed in `middleware`, before it.
- `DynamicPrompt` runs before the agent's other middleware: it replaces the
  declared `system_prompt`, and the sections that `filesystem`, `memory`,
  `skills` and middleware such as `TodoList` add follow it. The
  structured-response call after a tool loop uses its prompt too.
- `StructuredOutputRetry` puts the failed answer in the retry request,
  followed by the error as a tool message for each of its tool calls (tool
  strategy) or as a user message, and the saved thread keeps both. The model
  sees what it got wrong, and a scripted `"fake:chat"` model answers the
  retry with its next response.
- `ToolRetry` with the default `on_failure: :error` gives the model the tool's
  last error as the tool node wrote it, instead of wrapping it in a second
  "Tool error: …".

#### Subagents and deep agents

- A subagent with `inherit_messages: true` gets its task after a note that
  the conversation above is the parent's, which it continues as the subagent
  asked for help, using the facts that conversation established. The `task`
  tool's list marks such a subagent as one that sees the conversation, and
  its notes say a call is stateless unless the list says otherwise. Before,
  the task came right after the inherited messages, so the subagent could
  take the parent's request to delegate as one for itself, and the notes told
  the model that every call starts from the description alone.
- `interrupt_on: false` (or `%{}`) on a `subagent` line or spec turns review
  off for that subagent; before, it still took the parent's rules. A subagent
  without `interrupt_on` still takes the parent's.
- Subagents may take as many steps as the parent's recursion limit, instead
  of 9,999, unless they set `recursion_limit`. They start without the
  parent's private state, such as model and tool call counts and usage, so
  their own call limits count their own run. As before, they don't run the
  parent's middleware.
- With `capture_output:`, the parent's model reads `The <name> subagent
  finished the task. Its answer was saved as "<key>" and is not shown here.`
  (or that the saved answer was reused) instead of `"{}"`.
- A `subagents` list whose only entry turns the general-purpose subagent off
  raises `ArgumentError`.

#### Human review, checkpoints and resuming

- When a thread continues, a resume value that no pending interrupt claims
  goes only to the steps that run first. A `Graph.interrupt/1` reached later
  in the run pauses instead of receiving that value.
- Edited tool calls in a review are checked against the tool's own input
  schema, as well as against the rule's `args_schema`. An edit that doesn't
  match fails `resume_review/3` with `:invalid_human_decision`; before, the
  tool ran with the edited arguments and the model got a tool error.
- `interrupt.state` is the run's public state, as `get_state/2` shows it,
  without private channels.
- The HITL tool map no longer swallows arbitrary exceptions.

#### Graphs

- A `Send`'s `timeout` takes the forms a node's `timeout:` takes:
  milliseconds, a float of seconds, `ExecutionPolicy` or `TimeoutPolicy`
  options or structs. Before, an `ExecutionPolicy`, or options without
  `run_timeout` or `idle_timeout` (such as `[timeout: 100]`), became a
  5-second limit. An invalid `timeout` fails the `Send`'s task with an
  `:invalid_graph` error instead of becoming 5 seconds.
- A subgraph node's update holds only the keys the subgraph changed since it
  started, not its whole final state, and the subgraph's `input_schema:` and
  `output_schema:` apply. For a key with a reducer in the parent, the update
  holds what the subgraph added (the new end of a list, the new or changed
  entries of a map), so the parent's reducer no longer applies the values the
  subgraph received a second time (`notes: ["a"]` used to come back as
  `["a", "a", "b"]`); any other change to such a key replaces the parent's
  value. An `output:` function still receives the whole final state. A
  resumed subgraph no longer merges the parent's state into its own again,
  and its update leaves alone what changed in the parent while it waited:
  the writes of the other nodes of its step, a `Compiled.update_state/4`
  edit, and the `update` of the `Command` that resumed the run. A subgraph
  without checkpoints of its own (`checkpointer: false`) runs again, when
  resumed, on the state it started with.
- `AnyValue` keeps its value through steps that don't write it, as the Graph
  State guide describes; `update(any_value, [])` no longer clears it.
- A step's update (`GraphUpdate` events and checkpoint metadata) shows a
  reducer key's writes folded from the first write, without the channel's
  starting value, so a message removal appears as the
  `Graph.Messages.remove/1` marker it was.
- A reducer that raises fails the step with an `:invalid_update` error that
  carries the exception's message, instead of crashing the caller. A `Send`
  whose update can't be merged into the state (a reducer that raises, or a
  message the message reducer rejects) fails its own task that way, without
  running the node: the step's other tasks finish and the run returns
  `{:error, %BeamWeaver.Core.Error{type: :invalid_update}}`. It used to make
  `invoke/3` raise a `RuntimeError`, leave the run's trace open and send no
  `:exception` telemetry. A `Command` `goto` or a `Send` to a node the graph
  doesn't have fails its task the same way with an `:invalid_graph` error,
  instead of raising `KeyError`.
- `BeamWeaver.RetryPolicy.run/3` is the single retry loop behind graph node
  retries, `ModelRetry`, and `ToolRetry`.
- `use BeamWeaver.Graph.Channel` gives single-value channels (struct with
  `:key` and `:value`) default `get/1`, `checkpoint/1`, `from_checkpoint/2`,
  and `available?/1`; the bundled channels use them.
- `snapshot.pending_writes` of a step that stopped partway also lists a
  `"__route__"` entry for each task that finished in it: where the run goes
  from that task (its node, a `Command`'s `goto` and the `Send`s it returned).
  Code that reads the raw entries should skip it, as it skips `"__error__"`
  and `"__interrupt__"`.

#### Streaming

- Events a node writes (its `runtime.stream_writer`, tool events, a streamed
  model's `Token`, `MessageChunk` and `Done`) carry that node in
  `envelope.node`, and inside a subgraph or subagent the same namespace of
  node names as the run's other events, without the task id (`["billing"]`,
  not `["billing", "<task id>"]`). Tool events used to carry the checkpoint
  namespace split at `:`. Step events (`GraphUpdate`, `GraphValue`,
  `Checkpoint`, `Message`) have `node: nil`, live too.
- `runtime.stream_writer` does nothing during `invoke/3` and `resume/3`;
  before, each value was mailed to the run's process and thrown away.

#### Memory, storage and caching

- `refresh_ttl` on `Memory.GetOp` and `Memory.SearchOp` defaults to `nil`,
  which follows the store's setting, and `true` or `false` overrides it for
  that read; before, both stores ignored it. `Memory.search/3` takes
  `refresh_ttl:` too.
- The `:vector_store` migration raises `ArgumentError` for an `index:` other
  than `:ivfflat`, `:hnsw` or `false`, and for more than 2,000 dimensions
  with an index, instead of failing in Postgres or creating an `:ivfflat`
  index.
- `Memory.Ecto`, `Cache.Ecto`, `VectorStore.EctoPostgres` and
  `RecordManager.EctoPostgres` quote their table names the way the migration
  does, so names with capitals match the tables it created.

#### Tracing and telemetry

- Middleware trace spans are named after the middleware module, such as
  `TodoList.wrap_model_call`.

#### Retrieval, prompts and parsers

- `Runnable.invoke/3` and `Runnable.stream/3` call a chat model without the
  run's own `tags:`, `metadata:`, `run_id:`, `configurable:` and other run
  settings; its other options, such as `temperature:`, still reach it.
  `Prompt.structured_chain/3` works the same way, so the run's `metadata:` is
  no longer sent to the provider as request metadata.
- `BeamWeaver.Schema.module_schema/1` is the one lookup for a schema declared
  on a module (`json_schema/0`, `schema/0`, or `use BeamWeaver.Schema`);
  output-parser and structured-output schemas now also accept
  `use BeamWeaver.Schema` modules.

#### Filesystem and sandboxes

- `grep` adds a note to an empty result when the pattern looks like a regex
  (`|`, `.*`, `.+` or a backslash escape such as `\.` or `\d`): grep matches
  literal text, so the model should search for the literal text, once for
  each alternative. A search whose matches the read permissions all hid gets
  no note.
- `grep`'s description says the pattern is literal text, not a regex, and to
  run one grep for each of several strings. While the model is offered
  `execute`, it adds that a real regex needs `execute` with `rg`. The
  Filesystem middleware picks the description for each model call, and a
  description set with `tool_descriptions` stays. The system prompt's line
  for `grep` says it searches for literal text too.
- A `glob` or `grep` denied without a `path` says that it was checked against
  `/`, and to retry with a `path` inside an allowed directory (for `glob`,
  with a `pattern` relative to it). Their `path` no longer has a schema
  default; leaving it out still searches `/`.
- The `execute` file tool returns the command's output followed by its exit
  code, such as `[Command failed with exit code 1]`, and after a timeout an
  error that says the command was stopped, instead of only the output (and an
  empty string after a timeout). The filesystem system prompt says so.
- `Filesystem.Store` without a store returns the error `"missing_store"` from
  reads and writes, instead of reporting a write as done and dropping it.

#### Models and providers

- Anthropic's `effort:` turns on adaptive thinking with its summary, as
  `reasoning_effort:` does, on a model that takes only adaptive thinking;
  set `thinking:` to send something else. A call's `output_config` is merged
  over the model's instead of replacing it, and a call's effort, from any of
  the three options, wins over the model's. Claude Haiku 4.5 and Sonnet 4.5,
  which take no effort, reject `effort:` before the request instead of
  sending it.
- Requests check more of the model profile before they are sent: OpenAI and
  xAI reasoning efforts, Gemini thinking levels, and built-in tools a Gemini
  model lacks (computer use on Gemini 3.1).
- `base_url: nil` passed to a provider client's `new/1` means "not set" for
  every provider: the client falls back to application config, then the
  default URL. Moonshot, Z.ai, xAI, DeepSeek, and Google used to skip config.
- Anthropic and Google message and tool conversion return
  `{:error, %Core.Error{}}` only for invalid input (`ArgumentError`); other
  exceptions are no longer turned into errors and propagate as crashes.
- Model-name lookups no longer swallow arbitrary exceptions.
- A bare tool name as `tool_choice:` forces that function on OpenAI, xAI,
  Moonshot and DeepSeek (`tool_choice: "lookup_order"`), and `:any` means
  `:required`; OpenAI used to send the name as is.
- The tool strategy of structured output forces the schema tool
  (`tool_choice: :required`) only where the model allows a forced tool
  choice; on Kimi with thinking on, Z.ai, DeepSeek with thinking on, and
  Claude models that take only `:auto` or `:none`, it offers the tool without
  forcing it.
- Kimi K2.6 and K2.5 get a response schema as JSON mode with the schema in a
  system message, since they ignore a JSON Schema response format; an
  agent's `response_schema` now works on them.
- `RateLimiter.TokenBucket` children use their `:name` as child id (or
  `:id`), so several named buckets fit in one supervisor without
  `Supervisor.child_spec/2`.
- Z.ai PDF blocks are sent as Z.ai's documented `file` part
  (`%{"type" => "file", "file" => %{"file_url" => url}}`, or `"file_data"`
  with a data URL and the block's `filename`) instead of a `file_url` part.

#### Compaction engine

- The automatic-compaction limit (`maximum_auto_compactions_per_root_turn`)
  and the overflow retry count are per root turn: a request or checkpoint
  with a new `root_turn_id` starts them again. `Compaction.State` has a
  `root_turn_id` field.
- The compaction constructors no longer swallow arbitrary exceptions; only
  missing required compaction fields turn into `{:error, ...}`.

### Fixed

#### Agents

- An agent whose model can't take images or PDFs keeps working once its
  thread holds them, such as after `read_file` returned one: the model gets a
  notice in their place. Before, every later call failed with
  `:unsupported_feature`, a fallback to such a model too.

- Counting a thread's tokens approximately counts a file, audio or video
  content block as one media item, as it counts an image. Before, a PDF's
  block was counted by its base64 data, so a 1 MB PDF read as about 330,000
  tokens and could trigger summarization at once.
- A tool call that arrives without an id gets a generated one that no other
  call of the thread has, from `ToolCallNormalization` and for Gemini
  replies. Before, the ids were `call_<index>` and `call_<tool name>`, so they
  repeated from one turn to the next: a second large result of the same tool
  found its file path taken and stayed in the thread.
- The notice that replaces a large tool result or user message mentions
  `... [N lines truncated] ...` only when the preview leaves lines out, and
  says when it cuts lines longer than 1,000 characters. Before, it always
  mentioned omitted lines and cut long lines without saying so.
- A large tool result without a tool call id is saved under a generated
  name, also when `overflow_recovery` clips it. Before, every such result
  went to `/large_tool_results/unknown`, so the second one found the path
  taken and stayed in the thread.
- The filesystem section of the system prompt describes only the tools the
  model is offered: a tool removed with `exclude_tools` isn't mentioned, the
  `execute` section needs the `execute` tool, and the large-result guidance
  names `read_file` and `grep` only when they are there. Before, the prompt
  listed every file tool and told the model to grep saved results even when
  `grep` was excluded.
- Capability and provider profile keys split at the first colon, so a model
  id with colons of its own, such as an OpenAI fine-tune's `ft:...` id, gets
  its provider's profile and can have one of its own, from a spec string or
  a model value. Before, such a model got no profile at all, and registering
  its key raised `ArgumentError`.
- Structured output after a tool loop works on Anthropic and Gemini: the extra
  call for the structured answer now ends with a short user instruction
  instead of the model's own reply, which those providers reject. The
  instruction goes to that one request and is not added to the state.
- `BeamWeaver.Agent.invoke/3`, `stream_events/3`, `resume/3` and
  `get_state/2` use a call's `checkpointer:`, `store:` and `cache:` for
  agents from `build/1`. They used the ones given to `build/1` only, so a
  second call on the same thread started over and `get_state/2` returned
  `:error`.
- Options in a `tools do` block (`tool Mod, opts`) were silently dropped, and
  a toolkit module in `tools` raised `UndefinedFunctionError`. A toolkit
  module now adds the tools its `tools/1` returns, and `tool MyToolkit, opts`
  passes `opts` to it.
- Agent modules accept a `%BeamWeaver.Graph.Command{}` input to `invoke/2`
  and `stream_events/2` instead of raising `Protocol.UndefinedError`.
- An agent's `input_schema` checks new input only: a `Command` input, or an
  empty input on a thread with saved state, continues the thread without
  being checked. Before, a schema that requires a field, such as `messages`,
  rejected both, so such an agent couldn't continue a thread.
- `checkpointer/0` and `store/0` of agent and graph modules always returned
  `nil`, even when the module declared them, so a
  `%Agent.Subagent.Compiled{agent: MyApp.Module}` subagent saved its
  checkpoints with the parent's checkpointer instead of its own. They return
  the declared values, and a module may define either function instead of
  declaring it; declaring and defining the same one doesn't compile.
- An agent with a response schema returns each turn's own structured answer
  on a checkpointed thread. The thread kept the last turn's answer, so a later
  turn whose first model call made none, such as one that called a tool
  first, ended on the old answer. A model call that makes no structured
  answer now clears it.
- A tool call whose arguments came back malformed or truncated (an invalid
  tool call) gets an error tool message right after its assistant message
  before the next model call ("Tool call NAME with id ID could not be
  executed - arguments were malformed or truncated."), and the thread keeps
  it. Nothing answered it, so the model never learned the call failed, and
  providers that need every call answered refused the next request.

#### Middleware

- A model call whose middleware rewrites the thread, with an `Overwrite` of
  `messages` in an `ExtendedModelResponse` command, keeps the other messages
  the call saves: a message the rewrite kept takes its edit, a new message is
  added, and one the rewrite removed stays removed. Before, the rewrite and
  the reply were saved and the other messages were lost.
- The `compact_conversation` tool's summary call is retried as automatic
  summarization's is: up to 3 times when retrying can help, and once with
  the middle of the old messages cut out when they are over the summary
  model's context window. Before, one failed call failed the compaction.
- An empty memory file, such as an empty `AGENTS.md`, is left out of the
  system prompt. Before, on the disk and sandbox backends the empty-file
  reminder was put into the prompt as the file's memory.
- `ToolRetry`'s `tools:` takes tool modules as well as names; a module used
  to match no tool.
- `BeamWeaver.Agent.Middleware.ShellTool` works in an agent: its private state
  key is declared as a channel, so building the agent no longer fails with
  `UndefinedFunctionError` for `:term.new/1`. Its sessions are supervised
  and, for a run with a thread id, registered under that thread, so a run
  paused for human review and resumed reuses its session (or starts a fresh
  one when it has gone). A session with no command for `:idle_timeout`
  milliseconds (a new option, default 15 minutes, `:infinity` to turn it
  off) stops on its own, so a run that never reaches `after_agent` (a pause,
  an error, an early jump) doesn't leak a session process.
- Middleware hooks that return `{:jump, :model, update}` or
  `{:jump, :tools, update}` work: the agent calls the model, or runs the tool
  calls of the last assistant message, and then routes as usual. Before, the
  jump stayed set and the run looped until `:recursion_limit`. A jump to
  `:model` or `:end` (or a halt) from an `after_model` hook skips the
  `after_model` hooks left, as a jump from a `before_model` hook skips the
  hooks after it, so a guard that halts the run before a dangerous tool call
  stops it whatever `after_model` middleware is listed before it. A jump to
  `:tools` still lets them, such as the `interrupt_on` review, see the tool
  calls first.
- `ModelFallback` accepts `"provider:model"` strings in `fallbacks:` and
  resolves them like the agent's `model`. Before, a string failed every
  fallback call with `:agent_model_error`. An unknown provider raises
  `ArgumentError` when the middleware is built.
- `thread_limit` in `ModelCallLimit` and `ToolCallLimit` counts every call on
  a thread, across `invoke/2` calls: the thread counts are saved in the
  thread's checkpoints (it needs a checkpointer). Before, they started again
  with every run. `run_limit` still counts one run.
- `ModelCallLimit`'s end message lists only the limits that were reached.
- `ToolRetry`'s `on_failure: :continue` message names the tool's error once,
  as in "Tool 'lookup_order' failed after 3 attempts with timeout: The
  archive service timed out. Please try again.", instead of repeating
  "Tool error: … Args: …" inside it.
- `PII.stream_transform/1` holds back `Token` and `MessageChunk` text
  separately, and per model call, so a whole agent stream passes through it:
  the text no longer comes out doubled in the message chunks and empty in the
  tokens. A `Done` releases only its own model call's text.
- `overflow_recovery` saves the clipped tool results in the thread when the
  retry succeeds, so the next call doesn't overflow again, and with
  `Filesystem.State` keeps the offloaded file in the thread's files, so the
  preview's path points at the full result.
- `Summarization` and the `compact_conversation` tool sent
  `metadata: %{source: ...}` with their summary calls, meant for traces,
  which providers read as the request's own `metadata` field: xAI (both
  APIs) and DeepSeek's Responses API refused every summary call with
  `:unsupported_model_param`, so an agent with `compact_conversation` on an
  xAI model failed once summarization started, and Anthropic and OpenAI Chat
  Completions requests carried it as their own metadata, though Anthropic's
  field takes only `user_id`. The summary calls now carry it as
  `trace_metadata:`.
- An agent with `compact_conversation` lost its thread after the model
  compacted it: with the default settings, the next model call saw only the
  compaction's summary, and the newest messages and the user's request were
  dropped from the saved thread. Automatic summarization ran first, and the
  compaction then cut the summarized thread at its old position; a later
  automatic summary was also replaced by the older compaction summary. A
  compaction now applies once, before automatic summarization checks the
  thread, which it summarizes only if the compacted thread still reaches its
  trigger; when something rewrote the thread after the tool ran, such as a
  `Summarization` listed before `CompactConversation`, the compaction is
  dropped.
- The pending compaction of the `compact_conversation` tool is saved with the
  thread's checkpoints, so a run that pauses (for example with
  `interrupt_after: [:tools]`) or stops between the tool call and the next
  model call still applies it, once, when it continues on the thread. It was
  lost, and the model went on with the whole thread.
- `ToolCallLimit` with `exit_behavior: :end` answers every call of the batch,
  none of which runs: a refused call says it hit the limit, the others that
  they were stopped. It answered only the refused calls, so the thread's next
  turn failed with `:invalid_chat_history`, and a limit on one tool failed
  with `:tool_call_limit_parallel_end_unsupported` when the batch also called
  other tools. The batch no longer counts against the thread.
- `ToolCallLimit`'s final message names the exceeded limit when a batch has
  both allowed and refused calls (`exit_behavior: :end` or `:error`). It
  left out the calls the batch allowed, so the message read "Tool call limit
  reached: ." with no limit named.

#### Subagents and deep agents

- The general-purpose subagent works as the parent's twin: it gets the
  parent's `tool_descriptions`, its capability profile (the prompt suffix,
  hidden tools, tool descriptions and middleware), and the parent's own
  `Filesystem`, `Skills`, `Summarization`, `CompactConversation` and
  `ToolCallNormalization` entries in place of the ones it would build. The
  parent's other middleware stays the parent's. Before, it saw the default
  tool descriptions and none of the profile, and built default capabilities
  however the parent had configured its own.
- `list_async_tasks` fetches the status of an `interrupted` task, as it does
  for a running one, so a task a person resumed on the server shows its new
  status and result. Before, listing took `interrupted` as final and kept
  showing it until `check_async_task` was called.
- A subagent's own middleware replaces the `base_middleware:` entry of the
  same module, as an agent's own entry replaces a capability's, and runs
  where its own list puts it. Before, its own `Skills` with
  `base_middleware: [:deepagents]` failed the build with `graph contains
  duplicate declarations`, and its own `Filesystem` with a base `Filesystem`
  ran both: two filesystem prompt sections, and one set of file tools hid
  the other.
- A `SKILL.md` takes `allowed-tools` as a YAML list, block or flow, as well
  as a string of names separated by spaces or commas. Before, a list failed
  with "skill allowed-tools must be a string" and the agent skipped the
  skill.
- A `SKILL.md` description over 1,024 bytes is cut to that length, on a
  character boundary, and the skill loads with a logged warning; another field
  over its size limit fails with a message that names the field, its size and
  the limit, such as "skill license is 1100 bytes, over the limit of 1024".
  Before, the whole skill failed to load, and the message said only "skill
  description is invalid".
- Each async subagent tool offers only the arguments it reads, and
  `start_async_task` requires `subagent_type`; `check_async_task` and
  `list_async_tasks` tell the model that a status from an earlier call may be
  out of date. Before, every tool offered all six arguments, including an
  unused `subagent_name`, and `start_async_task` required only
  `description`.
- A subagent no longer overwrites a key the parent keeps private, such as one
  a middleware declares with `Graph.private_channel/2`: the subagent's value
  of it stays with the subagent. Before, a subagent that wrote a key of the
  same name replaced the parent's value when its `task` call returned.
- The general-purpose subagent leaves out the tools the parent excludes with
  `exclude_tools`, and its file tools follow the permissions of the parent's
  own `Agent.Middleware.Filesystem` entry when the parent's `middleware` list
  has one. Before, it was offered every tool and built its file tools from
  the declared `filesystem` permissions only, so it could write a file the
  parent was denied, or call a tool the parent was never offered.
- The general-purpose subagent and subagents with
  `base_middleware: [:deepagents]` summarize their conversations only when
  the agent does, with its `summarization:` settings and its
  `compact_conversation` `model:` when it has one. Before, they summarized
  whenever the agent had any `compact_conversation` settings.
- A `%Agent.Subagent.Compiled{}` with `capture_output: :key` crashed on its
  first `task` call.
- `skills ["/skills"]` titles the folder `**Skills**` in the system prompt
  instead of `**Skills Skills**`.
- `TodoList.new(tool_name: "plan")` names `plan` in its default prompt and in
  the error for parallel calls, and the todo tool names itself in its
  missing-`todos` error, instead of `write_todos`.
- A subagent starts without the parent's private state. Keys that only the
  parent declares private, such as the counts of its `ModelCallLimit` and
  `ToolCallLimit` or a key its middleware declares with
  `Graph.private_channel/2`, reached the subagent's state and were saved in
  its checkpoints; only keys the subagent declared private itself were left
  out. This holds for the `task` tool of `BeamWeaver.Tools.Subagents` in an
  agent's `tools` too.
- Agent modules that name each other, or themselves, as subagents
  (`subagents do subagent MyApp.Checker end` in `MyApp.Planner`, and the
  reverse) never finished their first call, reading each other's
  declarations until the process ran out of memory. A `subagent` line that
  leads back to a module being read is now read when that subagent is built,
  and building the agent checks each such subagent once.
- A `:structured_once` or `:research_then_generate` subagent whose own
  `middleware` lists a `ModelCallLimit` failed every `task` call with
  `graph contains duplicate declarations`. Its own `ModelCallLimit` now
  replaces the one-call limit of the mode.
- An empty string in a skill's frontmatter, such as a `metadata` value `""`,
  stays an empty string; it became an empty map and failed validation.

#### Human review, checkpoints and resuming

- A new message sent to a thread whose tool calls wait for review cancels
  the review. Each call of that turn that hasn't run gets a failed tool
  result, "Tool call send_email with id call_1 was not run: a new message
  came in while it waited for review." (`metadata.error_type:
  :review_cancelled`), right after the assistant message that made the call,
  and the model answers the new message. A subagent's review that paused the
  parent is cancelled the same way, through its `task` call, and a subagent
  that already finished keeps its answer. The thread keeps that order, so the
  next requests to providers that want a call's result right after the call,
  such as Anthropic and Chat Completions, succeed. A message added with
  `update_state/4` while the review waits does the same, and with
  `interrupt_mode: :per_call` the calls that already ran keep their results.
  Before, the review paused again, and once it was decided the call's result
  came after the new message, which those providers rejected on that request
  and every later one.
- After `resume_review/3` (or `resume/2`) fails because the resumed node
  returned an error, such as `:invalid_human_decision`, the interrupt stays
  pending: `get_state/1` still lists it, and the next valid resume completes
  the run. Before, the next resume paused with the same review again and
  only a second one continued. The failed resume still returns the error,
  but saves only the pending interrupt, without an `"__error__"` entry in
  `snapshot.pending_writes` that a later pause would keep.
- Static breakpoints can be resumed. `resume/2` continues past
  `interrupt_before` and `interrupt_after` on graphs and agents; before,
  graphs paused at the same breakpoint again and agents failed with
  `:invalid_chat_history`. A breakpoint inside a subgraph pauses the parent
  with the breakpoint's `timing` and `nodes`, and `resume/2` continues it;
  before, the parent's interrupt held the wrong fields and `resume/2` raised
  `KeyError`.
- `Compiled.update_state/4` on a paused thread: the thread stays paused and
  the next `resume/2` runs the paused node on the updated state, and a
  subgraph or subagent paused inside it continues where it paused instead of
  starting over on an empty state. Before, the resume paused again,
  `get_state/2` listed the interrupt twice, and a second resume failed with
  `:invalid_resume`. Updates of nodes that finished in the paused step are
  applied once, not twice. An update of a paused or failed thread keeps the
  stopped step's number and its tasks' ids (the update's checkpoint has the
  stopped step's `"step"` in its metadata).
- A struct, such as a `Date`, works as a resume value instead of raising
  `Protocol.UndefinedError`.
- The checkpoint facade loads a saver's module before checking which
  callbacks it implements. A saver built as a struct literal in dev or test
  (interactive code loading) was reported as lacking `put_many/3` and other
  callbacks until something else loaded its module.
- `Checkpoint.ETS.delete_thread/2` also removes pending writes whose
  checkpoint is already gone, and thread/namespace lookups match on the key
  prefix instead of scanning every table row.
- A thread saved with `BeamWeaver.Checkpoint.Ecto` (Postgres or SQLite) came
  back with string keys: `get_state/2`, `get_state_history/3`, a resumed or
  continued run and `update_state/4` saw `%{"messages" => ...}` where
  `Checkpoint.ETS` gave `%{messages: ...}`, for agents (`messages`,
  `structured_response`, extra keys) and graphs alike. A thread now reads back
  as it does from `Checkpoint.ETS`, maps nested in its values included (see
  the serialization change under Breaking changes), and declared channels
  always come back under the key the graph declares.
- On `Checkpoint.Ecto`, a `Send` task that paused or failed could not be
  continued: resuming it paused again forever, and continuing the thread ran
  `Send` tasks that had finished a second time, because the task's id
  changed when its update came back with string keys. A task's id no longer
  depends on whether its update's keys are atoms or strings.
- `update_state/4` and `bulk_update_state/4` rebuilt the checkpoint from the
  state `get_state/2` shows, dropping join progress, the run counts of guarded
  edges (`max_runs:`) and private keys saved with the thread, so a join
  waiting on a branch never fired. They now keep them, and an update made
  `as_node:` a node upstream of a join counts as that node's arrival.
- `update_state/4` on a thread whose last step failed applied the writes of
  the nodes that finished in that step twice and ran those nodes again. The
  thread now keeps its failed step, like a paused one: the update applies on
  top of the finished nodes' writes, and continuing runs the failed node.
  With `as_node:`, which a paused thread ignored, the update is that node's
  result in the stopped step: a node of the step that failed or paused
  doesn't run again (its pause is dropped), a node that finished routes with
  the update as its output, and the node arrives at the joins it is upstream
  of. When no node of the step is left to run, the step completes and `next`
  lists what comes after it.
- `update_state/4` without `as_node:` on a thread saved with `Checkpoint.Ecto`
  (Postgres or SQLite) didn't find the node that ran last, so the update
  dropped the thread's next steps (`next` became `[]`); it now updates as that
  node and routes from it, as with `Checkpoint.ETS`.
- `update_state/4` on a thread stopped at a breakpoint rebuilt `next` from
  the updated node's edges only: nodes that other branches had put next were
  dropped, and a node that a `Command`'s `goto` had put next was lost, so
  `next` became `[]` and continuing started a new run. `next` now keeps them;
  only the nodes that the updated node's own edges chose are chosen again.
- `%Command{resume: ..., update: ...}` keeps its update when the resumed node
  pauses again: the update is saved into the paused step first, as
  `update_state/4` saves one, so resuming three times with three updates keeps
  all three. When the step completes, `get_state/2` shows the update for
  `DeltaChannel` keys too. Before, the update lived only in the run: each
  pause after it dropped it for every key, so only the last update survived,
  and a completed step lost it from `DeltaChannel` keys after a reload.
- A run started with `%Command{update: ...}` and no `resume` saves the update
  for `DeltaChannel` keys as well, in `get_state/2` and in the history.
  Before, the run's result had the update but the saved state of a delta
  channel didn't.
- New input to a thread whose last step stopped partway (a node failed or
  paused) is saved into that step before it continues, as `update_state/4`
  saves an update, so it stays when the step stops again. Before, the input
  lived only in the run: a step that paused or failed again lost it for every
  key, and one that completed lost it from `DeltaChannel` keys after a reload.
  Continuing a thread after `update_state/4` on such a step now also runs the
  nodes that the finished nodes' writes trigger (`triggers:`), and an
  `EphemeralValue` key a finished node wrote reaches the next step; before,
  those nodes didn't run and the value was cleared. See [Durable
  Execution](docs/durable_execution.md#what-survives-a-crash).
- A resume map keyed by interrupt id gives every paused task the answers it
  already used, including tasks the map doesn't answer. A task paused at its
  second `Graph.interrupt/1` keeps its first answer when another task's
  interrupt is answered; before, it asked its first question again.
- Resuming from a stopped checkpoint earlier than the thread's latest saves to
  a new checkpoint after it. Before, the answers were saved on that earlier
  checkpoint, and a branch that had already gone on from it read them in its
  `DeltaChannel` state.
- A subgraph that pauses in several nodes at once, including an agent with
  `interrupt_mode: :per_call` run as a graph node or as a subagent, pauses the
  parent with every pause, and a map from their ids, such as
  `Map.new(interrupt.interrupts, &{&1.id, answer})`, resumes them all at once
  or one at a time; a single value is rejected with `:invalid_resume`. Before,
  the parent showed one pause and every form of resume failed with
  `:invalid_resume`.
- `bulk_update_state/4` schedules what comes next as `update_state/4` does.
  Each superstep counts as the result of `as_node:`, or of the node that ran
  last, and the nodes after it are in `next`; a task waiting at a breakpoint
  stays. Before, `next` was always empty, also with `as_node:`, and a task
  waiting at a breakpoint was dropped.
- `bulk_update_state/4` on a thread whose last step stopped partway (a node
  paused or failed) saves each superstep into that step, as `update_state/4`
  saves an update: the pauses and the failed node stay, an update made
  `as_node:` a paused node answers it, and the step still routes from the
  nodes that finished in it. Before, each superstep started a new step from
  the finished nodes' writes, dropping the pauses and errors, and the nodes
  after the finished ones never ran.
- `bulk_update_state/4` checks every superstep before it saves any: one that
  isn't a list fails the call with `:invalid_update` and nothing is saved.
  Before, the supersteps ahead of it were saved first.
- `%Command{resume: ..., goto: ...}` on a thread whose last step stopped
  partway, or that waits at a breakpoint, saves the `goto`'s nodes into that
  step before it continues, so a node the `goto` added that pauses or fails
  runs on the next resume. Before, `next` didn't list it, and the next resume
  finished the step without it.
- A config with `checkpoint_id: ""` (or `nil`) means the thread's latest
  checkpoint, as no id does: `get_state/2` returns it, and `invoke` and
  `resume` continue the thread. Before, `get_state/2` returned `:error` and
  `invoke` started the thread over from an empty state.

#### Graphs

- A `DeltaChannel` key whose reducer raises, such as a
  `Graph.Messages.delta_channel/1` key given a write that holds no messages,
  fails the step with `:invalid_update`, as a reducer key does. Before, the
  exception was raised out of `invoke/3`.
- `Graph.add_join/4`, and `deps:` with several nodes, fire when the upstream
  nodes finish in different steps, and when a thread continues after a
  failed or paused step: each upstream node's arrival is saved with its
  step's writes and with the thread's checkpoints. Before, the joined node
  silently never ran and the run still returned `{:ok, _}`.
- `Graph.Messages.remove/1` deletes a message by id. Before, every removal
  raised `ArgumentError` out of `invoke/2`. Removing an id that isn't in the
  list fails the run with an `:invalid_update` error.
- An agent or graph module (`use BeamWeaver.Agent`) can be a graph node:
  `Graph.add_node(graph, :support, MyApp.SupportAgent)` runs its graph as a
  subgraph, with its checkpoints, interrupts and events in the parent's run.
  Before, the run failed with a `:node_exception`.
- `Graph.validation_report/2` and `validate_static: true` follow the targets a
  node lists in `destinations:`, so a node that routes with `Command` or
  `Send` is no longer reported as a dead end.
- The graph's internal `:__node_outputs__` and `:__edge_runs__` keys leaked
  into node state from the second step on (`Send` workers included),
  `runtime.previous_state`, `Task` event payloads, node cache keys and
  `interrupt.state`, and, with the graph's join progress keys, into the
  state that `when:` functions of edges and `deps:` conditions receive. They
  now read the state as nodes do.
- `runtime.execution.run_id` was always `nil`.
- Graph `:node_timeout` errors and telemetry always report the node's
  configured timeout. When the step's backstop for a node task fired before
  the node's own per-attempt timeout, which can happen on a loaded machine,
  they reported the padded backstop budget instead (e.g. `60` for a `10` ms
  timeout, more with retries).
- Continuing a thread whose last step stopped partway, on an error or an
  interrupt, never ran what came after the nodes that had finished in that
  step: their edges, their `Command` gotos, their `Send`s and their guarded
  edges. The step now routes from every task that finished in it when it
  completes, whether the thread continues with `invoke/3` (also with
  `snapshot.config` or a `Command` without `resume`), `resume/3` or after
  `update_state/4`, and also when the step stops again before it completes.
- A `Command` with `goto` replaced the edges of every node that ran in the
  same step, not only its own, so a parallel branch stopped there. It now
  replaces only the edges of the node that returned it.
- Identical `Send`s in one step (same node, update and timeout), such as a
  map-reduce over `["refund", "refund", "ship"]`, ran once. Each now runs as
  a task of its own, with its own task id. A repeated `Send`'s task path and
  its record in `snapshot.next_tasks` carry a `"repeat"` count (1 for the
  second, 2 for the third). This also holds for the `Send`s of a `Command`
  given to `invoke/3`.
- Continuing a thread whose last step stopped partway ran only one of the
  unfinished `Send` tasks of each node, so in a map-reduce over `a`, `b` and
  `c` where `b` and `c` failed, `c` never ran, and `get_state/2` listed only
  `b` in `next_tasks`. Every unfinished `Send` now runs again and is listed.
- A `when:` function or `deps:` condition that raises made `invoke/3`,
  `resume/3` and `update_state/4` raise, while `stream_events/3` returned a
  `:stream_error`. The run now fails with
  `{:error, %BeamWeaver.Core.Error{type: :edge_exception}}` everywhere, with
  the exception's message, and in `details.node` the node the edge leaves
  (for a `deps:` condition, the node that waits); a live stream ends with
  that `Error` event.
- A subgraph whose task ran again, on the node's `retry:` or when the parent
  thread continued after a failure or a crash, merged the parent's state into
  its own a second time, so list reducers gained an extra copy. It now
  continues its own run where it stopped and takes only what changed in its
  input since it first ran. A subgraph compiled with `checkpointer: true`
  continues a call only if that call's run stopped partway.
- Replaying a parent graph from an earlier checkpoint ran its subgraphs on
  top of their earlier runs, doubling list reducers; a task's first run now
  starts its subgraph afresh.
- A subgraph node (a compiled graph, or an agent module used as a node)
  without an `input:` projection received the parent graph's private keys,
  and saved them in its own checkpoints, when it had no `input_schema`. It now
  gets the parent's public state only; an `input:` projection still decides
  for itself what the subgraph receives.
- A run reads its thread's checkpoint once, when it starts. Before, each
  checkpoint write first read back the checkpoint before it, which the run
  had just written or read, so every step cost two round trips to the saver
  (a query and an insert with `Checkpoint.Ecto`). The run now keeps what the
  next write needs from the checkpoint it last wrote or read; the
  checkpoints written are the same. A ten-node graph on `Checkpoint.ETS`
  runs about 12% faster.
- `Graph.ServerInfo.new/1` keeps a user's `is_authenticated: false`; it
  became `nil`.
- A `DeltaChannel` key reads back each write as it was written: a list written
  once is one write, and a `nil` write is kept. Before, a reload split a list
  write into its items and lost a `nil` write. Checkpoints saved earlier read
  as they did.
- Messages written to a `Messages.delta_channel/1` key get their ids once,
  before they are applied, streamed or saved. This covers strings,
  `{role, content}` tuples, maps and the messages in an `Overwrite`, written
  by nodes, as input, with `update_state/4` or by a paused step's finished
  nodes. Before, every read gave them new ids, so `Messages.remove/1` with an
  id the run returned did nothing. `DeltaChannel` takes `prepare:`, the
  function that does this.
- A key changed from a `DeltaChannel` to another channel keeps its value, in
  `get_state/2` and `get_state_history/3`, and the next run adds to it.
  Before, it read `nil` or a raw snapshot, and the next run started it over.
- `get_state/2` on a thread with `DeltaChannel` keys reads checkpoints only
  back to each key's last snapshot, and `get_state_history/3` reads no
  checkpoint again. On `Checkpoint.Ecto` (Postgres or SQLite) those
  checkpoints are listed a page at a time, so reading 60 of them back takes 6
  reads instead of 61. Before, every read went back to the thread's first
  checkpoint, once per key: a history of 800 checkpoints on Postgres took
  almost four minutes, and now takes 49 ms.

#### Streaming

- `stream_events/3` without `live: true` returned the steps in reverse order
  and each step's state events reversed, wrapped the model's `Token`,
  `MessageChunk` and `Done` events in `Events.Custom`, repeated each
  `Message` a node wrote as a `Custom` event, and ignored `stream_mode:`.
- Live streams sent every subgraph event twice.
- A live stream whose top-level run ends with a `Command` for a parent graph
  (`graph: :parent`) ends with an `Error` event holding the `:parent_command`
  error that `invoke/3` and a collected stream return. Before, it ended with
  a `Debug %{type: :parent_command}` event, as if the run had succeeded.
- A live stream no longer leaves a `{ref, {:beam_weaver_mux_done, pid, :ok}}`
  message in the reading process's mailbox, where a GenServer or LiveView
  `handle_info/2` would receive it.
- `BeamWeaver.Stream.Subgraphs.from_events/2` and
  `BeamWeaver.Stream.Lifecycle.from_events/2` report a subgraph that failed as
  `:failed`, with its error's message, and one that paused as `:interrupted`.
  They reported both as `:completed`: they looked for an `Error` event in the
  subgraph's namespace, but a subgraph that fails sends none, since only a
  run that fails ends with an `Error` event, at the top level. A subgraph's
  status is how the node that ran it ended, from that node's `Task` events in
  the parent's namespace (the default stream mode, `:tasks` and `:debug`
  include them), so a subgraph that the node's `retry:` ran again until it
  succeeded, or whose failure the node's `error_handler:` handled, is
  `:completed`. The Streaming guide's Subgraphs section has an example.
- An agent's stream no longer has a `Debug` event `%{type: :producer_start}`
  and one `%{type: :producer_stop}` for each streamed model call on OpenAI,
  xAI, Kimi, Z.ai and DeepSeek models. The typed stream of these models
  (`ChatModel.stream_typed_events/3`) sent them for the process that reads
  the provider's response; Anthropic's and Gemini's streams have no such
  events. A run's stream still starts and ends with its own.
- `stream_mode: :messages` streams the messages that several nodes write in
  one step to a `Graph.Messages.delta_channel/1` key. Before, such a step
  streamed none of them.

#### Memory, storage and caching

- `Checkpoint.Ecto` gives a checkpoint saved without an id, as every graph and
  agent run saves them, a UUIDv7 id. The ids came from a counter that starts
  again whenever the VM boots, so a thread that continued after a restart or
  a deploy reused ids it already had, and the saver overwrote those older
  checkpoints in place: the thread's history and state came back wrong.
  Checkpoints saved earlier keep their ids.
- Encryption works in `Checkpoint.Ecto` and `Cache.Ecto`:
  `serialization: [codec: Serialization.Encrypted, encryption_key: key]` lost
  the key, so every write failed with `:invalid_serialization_key`. With
  encryption, checkpoint history is no longer empty, metadata filters match
  after decrypting, and `Checkpoint.delete_for_runs/2` finds the runs'
  checkpoints.
- `Memory.ETS` removes a record's embeddings when it prunes, sweeps or skips
  the expired record.
- A graph node with `cache:` failed every run with
  `:unsupported_serialization_type` when the cache was `BeamWeaver.Cache.Ecto`.
  Its result is now saved and reused.
- `Checkpoint.ETS` reads only what it is asked for. It finds a thread's
  latest checkpoint without copying all of the thread's checkpoints out of
  the table, `list/3` (and `get_state_history/3`) reads only the thread in
  the config instead of every thread, pending writes are read by key instead
  of copying the whole writes table, and a checkpoint comes with its parent's
  pending writes, so reading it no longer reads the parent as well.
  `get_state/2` on a thread with 50 checkpoints went from 0.24 ms to 0.02 ms,
  and `get_state_history/3` on a saver with 1,000 threads from 19 ms to
  0.04 ms.
- Saving a checkpoint no longer rebuilds its metadata when there is no NUL
  byte to strip from it. With the change above, a ten-node graph with
  `Checkpoint.ETS` runs about 20% faster.
- A read that refreshes a record's TTL (`refresh_ttl`) no longer undoes a
  `put` that runs at the same time. `Memory.ETS` wrote back the record it had
  read with a new expiry, so a `put` between the read and the refresh was
  lost, and `Memory.Ecto` could give a record put meanwhile with `ttl: nil`
  an expiry. Both now refresh the record as it is stored, with its own
  lifetime, and leave a record without one alone.
- `Memory.search(store, [])` on `Memory.Ecto` returns the records of every
  namespace, as on `Memory.ETS`; it returned `[]`.
- `Serialization.load/2` returns a `:serialization_error` for an encoded atom
  whose value isn't a string and for an encoded tuple whose items aren't a
  list, instead of raising.
- SQLite checkpoint migrations given the singular
  `adapter: {:checkpoint, checkpoints_table: ..., writes_table: ...}` check
  the version of those tables. They checked the default table, so a rollback
  left the named tables in place.
- `Memory.search/3` with `filter:` skips records whose value isn't a map
  instead of raising `FunctionClauseError` in the ETS store.
- `Memory.get_many/3` returns a stored `{:error, _}` value as that value
  instead of reporting a failed read.
- A cached graph node's `ttl:` counts from the run that saved the entry.
  Before, every cache hit wrote the entry again, so an entry that kept being
  hit never expired.
- A node whose `error_handler:` supplied the result is not cached. Before, the
  fallback was saved under the node's cache key, so later runs with the same
  input skipped the node and got the fallback.
- `BeamWeaver.Memory.list_namespaces/2` on `Memory.Ecto` no longer lists a
  namespace whose records have all expired.
- Reading an expired memory record or cache entry, or sweeping expired ones
  in `Memory.ETS` or `Cache.ETS`, no longer deletes a value put under the same
  key at the same moment.
- A checkpoint holding a value that can't be rebuilt any more loads. A struct
  whose tag is no longer registered, or whose module was removed, comes back
  as a map of its fields, and an atom that no loaded code uses comes back as a
  string, with one warning per tag or atom. Before, one such value made the
  whole checkpoint unreadable (`:checkpoint_read_failed`, and
  `Checkpoint.get_tuple/2` raised). `BeamWeaver.Serialization.load/2` behaves
  the same way. See [Serialization](docs/storage.md#serialization).
- `Checkpoint.prune/3` keeps what a thread's `DeltaChannel` keys still read:
  every key's history on the latest checkpoint's branch, including writes
  saved only by a paused step. The first checkpoint it keeps becomes the
  thread's first, so `fork_at/4` works after a prune, and it also removes the
  checkpoints of subgraph calls that finished. Before, a prune could lose
  delta key values (after a fork, with several keys, or a paused step's
  writes), left `fork_at/4` failing with `:checkpoint_lineage_missing`, and on
  `Checkpoint.Ecto` read every checkpoint with its pending writes.
- `Checkpoint.delete_for_runs/2` makes a checkpoint whose parent it deletes
  the first of its thread, as `Checkpoint.prune/3` does, so `fork_at/4` can
  copy it. Before, the checkpoint kept pointing at the deleted parent, and
  `fork_at/4` failed with `:checkpoint_lineage_missing`.
- `Checkpoint.ETS` keeps a checkpoint's parent when the same checkpoint is put
  again, as `Checkpoint.Ecto` does. Before, putting it under one of its
  descendants made the two each other's parent, and reading delta history from
  them never returned.

#### Tracing and telemetry

- The local trace store no longer grows without bound: every graph run added
  about six runs that stayed until the node restarted. A run whose process
  exits before finishing it, such as a node or tool task killed at its
  timeout, now ends with `status: :error` and
  `error: %{kind: :exit, reason: ...}` in the store, so `max_runs:` removes
  it like the other finished runs; it stayed `:running` and was never
  removed, even with `max_runs: 0`.
- The WeaveScope export queue uploads the traces still queued when it stops,
  for example when the application shuts down; before, it logged an error
  and dropped them.
- A graph run that failed before its first step left its trace run open.
- Traced calls spend far less time redacting secrets, with the same redacted
  result. Text without a secret marker (`=`, `@`, `Bearer`, `sk-`, a private
  key header) no longer goes through a JSON decode and six regular
  expressions, the `NAME=value` pattern runs only when a name such as
  `api_key` or `token` comes before the `=`, and a model call's run no longer
  redacts its start metadata (tool definitions included) a second time when
  it finishes. Redaction took most of an agent call: one tool call on
  `"fake:chat"` went from about 3 ms to 0.4 ms, and a deep agent's `task`
  call from about 10 ms to 1.3 ms.
- Traced calls spend about a third of the time they did redacting secrets,
  with the same redacted result (a test compares it with a plain reading of
  the rules over random terms). The parts of a value with nothing to redact
  come back as they are instead of being copied, the keys that every message
  repeats (a tool call's fields, the summary of a provider response) are
  checked once per node, a key's name takes one search, and long text skips
  the patterns it can't match: an `=` in code or prose no longer runs the
  query and assignment patterns, and an email address next to a link no
  longer runs the URL credentials pattern. Redacting a 160-message
  conversation went from 0.8 ms to 0.13 ms. Redaction took 20–35% of an agent
  call and now takes 6–18%: one tool call on `"fake:chat"` is about 20%
  faster, a deep agent's `task` call about 25%, and calls on a long thread
  about 25%.
- Exporters, such as WeaveScope's, get the `:error` event of a run whose
  process exits before the run ends, such as a node or tool task killed at
  its timeout. The exporter the run started with gets the run once, with
  `status: :error` and the redacted `error: %{kind: :exit, reason: ...}` the
  trace store gives it, from a separate process, so an export queue that
  makes callers wait never holds up tracing. Before, exporters got no end
  event and WeaveScope showed the run as running forever. A run that ended
  before its process exited is exported as before, with no second event.
- An exporter set in config (`config :beam_weaver, tracing: [exporter: ...]`)
  or in a call's `exporter:` option gets events even when nothing has loaded
  its module yet. In development and tests, where modules load on first use,
  it got none until something else called the module.
- The WeaveScope exporter maps a run kind given as an atom the way it maps
  the string, so `:generation` exports as `"generation"`, not `"span"`.

#### Retrieval, prompts and parsers

- Incremental and full indexing cleanup no longer deletes a source's old
  chunks when its new chunks failed to write; they stay searchable until a
  later run writes the new ones. Before, a failed batch left the source with
  no chunks at all.
- `VectorStore.add_documents/3` and `from_documents/3` accept the stream that
  `TextSplitter.split_documents/2` returns, or any enumerable of documents,
  instead of raising. A stream that raises while it is read returns
  `:invalid_documents`.
- `VectorStore.as_retriever(store, search_type: :mmr, mmr_lambda: x)` uses
  `x`; it always searched with 0.5. `mmr_lambda:` passed to
  `Retriever.retrieve/3` overrides it.
- `TextSplitter.html_headers/1` keeps headings that aren't in `headers:` as
  text of the section; it filed them under a `nil` metadata key.
- `TextSplitter.markdown_syntax/1` gives every chunk its document's metadata;
  only the last chunk had it, so incremental indexing could lose the other
  chunks' `source`.
- `Runnable.sequence/2` can pipe a prompt into a chat model, and
  `Runnable.invoke/3`, `stream/3` and `batch/3` accept a string for a chat
  model. Both failed with `:runnable_exception`, because the model got the
  prompt value or the string instead of a message list.
- `OutputParser.schema/2` takes a `BeamWeaver.Schema` module, or any module
  that declares a JSON schema; it always failed with "schema parser expected
  an object". A module without a schema raises `ArgumentError`.
- A value passed to `Prompt.format/3` overrides a partial of the same name
  when one uses an atom key and the other a string key; the partial won.
  `Prompt.partial/2` replaces an earlier partial the same way.
- `Prompt.save/3` saves chat prompts with literal messages, such as
  `Message.system("...")`, as messages whose braces stay text; it raised
  `FunctionClauseError`. A prompt part that can't be saved returns an error.
- `Prompt.load/2` reads a YAML prompt file back as it was saved. An empty
  string or an empty list came back as `%{}`, so a saved literal
  `Message.assistant("", tool_calls: ...)` failed to load with
  `:invalid_content` and a prompt with an empty partial failed with
  `:runnable_exception` when formatted, and a list of integers such as
  `[104, 105]` came back as the string `"hi"`. A key that isn't a plain name,
  such as `"label: #1"`, is now quoted when saved instead of making the file
  unreadable, and a file that isn't valid YAML returns
  `:invalid_prompt_spec` with the line and column instead of crashing the
  caller with a yamerl throw.
- Pinned requests to an IPv6 address, such as `split_url/3` on a host that
  resolves to one, connect instead of failing with `:nxdomain`.
- A `schema` output parser parses partial JSON with
  `OutputParser.parse_partial/2`, and returns `nil` until the value matches
  the schema; it failed on incomplete JSON.
- Pretty-printed JSON (`Prompt.save/3` to a `.json` file, the schema in the
  JSON-object mode instruction, recorded cassettes) handles atom values and
  structs such as `DateTime` the way compact JSON does, instead of raising.

#### Tools

- A struct given for an `"object"` argument fails the tool's input check with
  `:invalid_input`, as a value of any other wrong type does. Before, the check
  raised `Protocol.UndefinedError`.
- Tool modules may return `{:error, reason}` with any reason, or a bare value,
  like function tools. Before, anything but `{:ok, value}` or
  `{:error, %Core.Error{}}` raised `WithClauseError`. A string reason, from a
  module or a function tool, is now the error message the model reads instead
  of "tool returned an error".
- Tool error messages no longer end the error's own sentence with a second
  period (`"Tool error: No order B-7.. Args: …"`).
- An agent keeps the artifact of a `response_format :content_and_artifact`
  tool, and the documents of `Retriever.as_tool(retriever,
  response_format: :content_and_artifact)`, in the tool message's
  `metadata.artifact`; it dropped them.
- A tool module without `description` is described by its `@moduledoc`; it
  got an empty description.
- A property typed `"null"` in a tool's input schema or a structured-output
  schema accepts only `nil`; it accepted any value.
- A `$ref` to an integer-keyed entry, such as `#/$defs/400`, resolves even
  when the segment also names an existing atom. It failed with
  `:json_schema_ref_not_found` depending on which atoms the VM had created.

#### Filesystem and sandboxes

- A `Composite` with a route below a folder of its default backend, such as
  `/workspace/memories/`, lists and searches it from every folder above it:
  `ls /` shows `/workspace`, `ls /workspace` shows `/workspace/memories`, and
  `glob` and `grep` of `/workspace` search the route too, also when the
  default backend has nothing else there. Before, `ls /` listed
  `/workspace/memories` as an entry of `/`, `ls /workspace` left it out, and
  only a search of `/` searched the route.
- Docker `grep` finds matches with a glob that has `/`, such as
  `src/**/*.py`, leaves out binary files and `.git` folders below the path
  searched, and returns an error for a path that doesn't exist
  (`file_not_found`), a failed search, or a relative path. Before, a glob with
  `/` returned `[]`, `.git` was searched, every error came back as `[]`, and a
  relative path raised.
- Docker's file operations read the whole output of their commands. Before, a
  `grep`, `ls` or `read` whose output passed `max_output_bytes` was cut and
  came back incomplete or as an invalid response.
- The local sandbox's `read/3` splits lines as the other backends do: a final
  newline adds no empty line, `\r\n` and `\r` end lines, a negative `offset`
  reads from the start, and `limit` defaults to 2,000 lines. Before, it
  returned the final newline, kept `\r`, read a negative `offset` from the
  end, and returned the whole file when no `limit:` was given.
- `Filesystem.Conformance.check_symlinks/3` also checks that `write_file`
  can't replace a denied file through a link.
- `Filesystem.Composite` returns the error of a backend that fails when it
  lists `/` or searches `/` with `glob` or `grep`. Before, `ls /` listed only
  the routes when the default backend failed, and a search of `/` left out a
  failing backend's matches without an error, so the results looked
  complete.
- `grep` on `Filesystem.Local`, `Filesystem.LocalShell` and `Sandbox.Local`
  leaves out binary files and `.git` folders below the searched directory.
  Before, one binary file with a matching line made the whole `grep` call
  fail, losing the matches in text files, and `.git` internals were
  searched.
- `Sandbox.Docker.edit/5` changes only the text it replaces, `write/4` of an
  existing file returns `"file already exists"`, `upload_files/3` replaces
  existing files, and a bad path in `upload_files/3` or `download_files/3`
  fails only its own file; a missing file is `"file_not_found"`. Before,
  `edit/5` rewrote the file from a 2,000-line read, dropping later lines,
  the final newline and `\r\n` line ends, and reported success without
  editing a file that isn't UTF-8; writing an existing file returned an
  empty error, which the model saw as `Error: `; an upload couldn't replace
  a file; and one bad path raised for the whole batch.
- Changes to different files in one model turn all apply on
  `Filesystem.State`, the default filesystem. Before, each `write_file` and
  `edit_file` call of the turn returned the whole files map and the last one
  won, so an edit next to another edit or write, or next to a large tool
  result saved to a file, was undone although its call reported success. A
  second `write_file` or `edit_file` on a path an earlier call of the same
  turn changes is now refused with an error, on every backend, so changes to
  one file can't race.
- Shell commands that run past their timeout are now stopped together with
  every process they started: their process group gets SIGTERM, then SIGKILL
  one second later. A command is stopped the same way when the process
  running it dies before it returns, such as a tool task ended with
  `Task.shutdown(task, :brutal_kill)`. Before, the shell tool
  (`HostExecutor` and `Session`), `Filesystem.LocalShell`, `Sandbox.Local`,
  and `Sandbox.Docker` only abandoned the command, which kept running in the
  background (inside the container, for Docker). The shell tool's
  `kill_attempted` timeout metadata is now accurate, `Sandbox.Docker` starts
  containers with `docker run --init` so stopped processes are reaped, and
  `LocalShell` and `Sandbox.Local` commands read EOF on stdin like the shell
  tool's.
- `Filesystem.Store` lost every write on `Memory.Ecto`: files are now saved
  as plain maps (`"content"`, `"encoding"`, `"created_at"`, `"modified_at"`),
  and a store read or write that fails comes back in the result's `error`,
  which the model sees as `Error: ...`, instead of a success. A write saves
  only the file it changed, and a store no longer sees the files of nested
  namespaces (`["acme"]` used to list the files of `["acme", "policies"]`).
- `glob` on `Filesystem.State` and `Filesystem.Store` missed top-level files
  for patterns such as `**/*.md`: `**/` now matches zero or more
  directories.
- A `Filesystem.State` backend under a `Filesystem.Composite` route saved
  `/scratch/x.md` as `/x.md` and listed the default backend's files under the
  prefix. Routed backends now get the route's prefix as the `:route_prefix`
  option, and `State` keeps its files under their full paths. `ls`, `glob`
  and `grep` from `/` no longer return a routed `State` file twice.
- `Filesystem.State.download_files/3` returns `"invalid_file_data"` for
  content that isn't valid base64 instead of raising.
- `glob` and `grep` on `Filesystem.Local` and `Filesystem.LocalShell` found
  nothing, or searched another directory, when the directory's own path had
  a glob character in it, such as `/srv/notes [draft]`.
- A malformed pattern, such as `{a,b` without its closing brace, made `glob`
  and `grep` on `Filesystem.Local`, `Filesystem.LocalShell` and
  `Sandbox.Local` raise; they return the error `"invalid_pattern"` instead.
- A shell `Session` survives a non-UTF-8 exported variable
  (`export X=$'caf\351'`). Such a value made every later command fail with
  `UnicodeConversionError` until the session restarted. Command environment
  values now pass their bytes through unchanged (`:binary.bin_to_list/1`),
  which also stops a UTF-8 value being re-encoded as Latin-1.
- `Sandbox.Local.read/3` returns a binary file whole, as `Sandbox.Docker` and
  `Filesystem.Local` do. It applied `offset:` and `limit:` as a byte range, so
  the `read_file` tool's default line limit cut binary files to 2000 bytes.
- `Sandbox.Local` reports reading or editing a directory as `"is_directory"`,
  like `Filesystem.Local`, instead of `":eisdir"`.
- `Sandbox.Local.edit/5` with an empty old string reports `"string not found"`
  as the other backends do; on an empty file it wrote the new text.

#### Models and providers

- Chat Completions requests (OpenAI, xAI, Moonshot, Z.ai and
  OpenAI-compatible services) send a tool result's images and PDFs in a user
  message right after the run of tool results, each under a line naming its
  call, and keep the tool's text in the tool message. Before, OpenAI and xAI
  dropped the media, and Moonshot and Z.ai sent the blocks' `inspect/1` text,
  base64 data included, as the tool result.
- Gemini gets a PDF from a tool result in the function response's parts,
  with its MIME type, as it gets images. Before, the PDF went into the
  response JSON as a map holding its base64 data.
- OpenAI and xAI model profiles, and the `grok-*` family profile, list PDF
  input, and the fake chat model's profile lists image and PDF input.
  Before, they had `pdf_inputs: false`, although these APIs take PDFs.

- Context overflow errors from OpenAI-compatible servers are typed
  `:context_overflow`: llama.cpp's "exceeds the available context size",
  LiteLLM's `ContextWindowExceededError` and "context limit exceeded", Text
  Generation Inference's "`inputs` tokens + `max_new_tokens` must be <=" and
  "`inputs` must have less than", and a 413 or 422 whose message says the
  prompt is too long. `overflow_recovery` recognizes the same wordings in an
  error of another type, such as one a proxy passes on. Before, these were
  `:invalid_request` or `:http_error`, so `overflow_recovery` and the
  summary's cut-the-middle retry didn't act.
- An xAI error keeps xAI's message, such as "Incorrect API key provided";
  it used to read "xAI request failed with HTTP 400".
- Claude Opus 4.8, Fable 5 and Mythos 5 take a system message partway
  through a conversation, as Anthropic documents; they used to refuse it
  with `:invalid_messages`.
- Claude Sonnet 4.6's profile allows 128,000 output tokens, Anthropic's
  limit, and so does its default `max_tokens`; both were 64,000.
- `openai:gpt-daybreak-blue-latest`, an alias OpenAI deprecated, fails with
  `:deprecated_model` and names its model, `gpt-5.6-sol`.
- Anthropic agents that stream (`stream: true`) can use tools, and their
  streamed reply has the same content as a non-streamed one, its thinking
  with the signature included: the request after a streamed tool call no
  longer replays the stream's `input_json_delta` fragments, empty text blocks
  and stream positions.
- Agents whose model streams (`stream: true`) keep the whole reply on OpenAI
  Chat Completions, Anthropic, Moonshot (Kimi), Z.ai and xAI Chat Completions
  models. The typed event stream of these models
  (`ChatModel.stream_typed_events/3` and `stream_events/3`) now ends with a
  `Message` event holding the complete reply, followed by the `Done` events:
  on Moonshot and Z.ai the reply `stream_response/3` returns, on the others
  the reply decoded as for a call without streaming, xAI's with its
  `reasoning_content` and `citations` metadata. An agent's streamed reply
  used to be rebuilt from the text and tool-call chunks alone, so it lost its
  reasoning, its `usage_metadata` and its provider metadata
  (`model_provider`, `id`, `request_id` and the rest), and an agent on a
  Kimi thinking model didn't send the reasoning back with the tool results,
  as Kimi requires. OpenAI's Responses API stream already ended with the
  complete reply.
- xAI's `ChatCompletionsModel.stream_response/3` keeps the reply's
  `reasoning_content` and `citations` metadata, like a call without
  streaming: the reply was rebuilt from the streamed text and tool calls
  alone. OpenAI's Chat Completions `stream_response/3` reply now also keeps a
  streamed refusal and the log probabilities of every token, not just the
  last chunk's.
- A streamed Kimi reply holds its reasoning in one `:reasoning` block instead
  of one block per streamed piece.
- `Models.cached/3`, `with_rate_limiter/2`, `bind_tools/3`, and
  `with_structured_output/3` work when the call is traced, which includes
  every call inside an agent or graph. Tracing read the wrapped model as a
  string and raised `Protocol.UndefinedError`.
- OpenAI Chat Completions, response retrieval, input-item listing, response
  compaction, and moderation requests now honor a custom endpoint or
  `:base_url`, and `OpenAI.Images.generate/2` honors `:base_url`, instead of
  always calling `api.openai.com`. `OpenAI.Client` gained `:base_url` and
  `:chat_completions_endpoint`; `OpenAI.Client.endpoint/2` takes a client or
  base URL.
- `init_embeddings/2` for OpenAI and xAI reads the API key (and base URL)
  from the provider's config group; it used to send no `Authorization`
  header.
- Moonshot, Z.ai, and xAI clients no longer send per-call `:headers` twice.
- A Responses API built-in tool (such as web search,
  `%{"type" => "web_search"}`) given to a Chat Completions model returns an
  `:unsupported_feature` error; it used to become an empty function tool (a
  Moonshot model raised `ArgumentError`, and a DeepSeek model returned
  `:invalid_request`). `ChatCompletions.Messages.tool_to_openai/1` and
  `Moonshot.Tools.to_chat_tool/1` raise for it.
- OpenAI, xAI and DeepSeek Responses requests return an
  `:unsupported_feature` error for a video block or an audio block without
  data, OpenAI and xAI Chat Completions requests for a block they have no
  part for, such as video, audio given by URL, an image given by `file_id`,
  or a citation (with `details: %{api: :chat_completions, feature: type}`),
  and Moonshot requests for citation and tool-result blocks. They used to
  raise `Protocol.UndefinedError`.
- Anthropic requests return an `:invalid_content_block` error for a block
  Anthropic has no input for (video, audio, citation), also in a system
  message, instead of raising `Protocol.UndefinedError`; an image given by
  `file_id` is sent as a file source instead of raising
  `FunctionClauseError`.
- Agents with Anthropic server tools, such as `Anthropic.Tools.web_search/1`,
  work past the first search: the next request sends the `server_tool_use`
  and `*_tool_result` blocks exactly as Anthropic returned them. They used to
  be rebuilt with `args`, `output`, `status` and `tool_call_id` fields (or,
  when streamed, with an empty `input` and `server_tool_call_chunk` blocks),
  and Anthropic rejected the request. A streamed reply saved by an earlier
  version is sent correctly too; a non-streamed one lacks Anthropic's result
  blocks, and sending it returns an `:invalid_content_block` error.
- A reply sent to another provider or API, as after a model fallback, goes
  as its text and tool calls, and its reasoning is left out. An Anthropic
  reply went to OpenAI's Chat Completions API with its thinking, redacted
  thinking and tool calls as content parts, and to the Responses API with
  them as items and with Anthropic's ids as item ids; OpenAI rejected both.
  A Responses API reply named its tool calls by their `function_call` item
  ids (`fc_...`) on Chat Completions, which the tool results don't answer,
  and went to Anthropic with its unsigned reasoning as a thinking block,
  OpenAI's fields on its text and the tool input as a JSON string. A Chat
  Completions reply went to the Responses API with its `chatcmpl-...` and
  `call_...` ids as item ids. Chat Completions now leaves an assistant's
  reasoning, tool-call and provider tool blocks out of its content and names
  each call by the `call_id` its result answers; the Responses API takes
  another provider's or API's reply as an `output_text` message and
  `function_call` items keyed by `call_id`, without ids; Anthropic takes it
  as text and `tool_use` blocks. Replies are sent back to their own provider
  as before.
- Kimi K2.6 and K2.5 accept `tool_choice: :required` with thinking disabled.
- Z.ai validates `thinking` and `reasoning_effort` against each GLM model's
  profile, so GLM-5.3 rejects efforts and thinking modes it does not support
  instead of being checked against the GLM-5.2 list.
- Z.ai returns `{:error, %Error{}}` for content blocks a model can't take,
  such as a file block on GLM-5.2; it used to raise.
- A Z.ai model created with `stop:` sends those stop sequences; only a call's
  own `stop:` was sent.
- Moonshot quota errors (`exceeded_current_quota_error`, which Kimi sends as
  the error's `type` with HTTP 429 or 403) are `:quota_error` with
  `retryable: false`, so retry middleware no longer retries them. One without
  a `code` field used to be a retryable `:rate_limit_error`.
- Kimi's `engine_overloaded_error` is an `:overloaded_error` (it was a
  `:rate_limit_error`; both are retried), and its "prompt tokens + max_tokens
  exceeds the model specification" error is a `:context_overflow`.
- Z.ai errors are classified by their documented codes, given as a string or
  a number, with or without streaming: 1301 is `:content_filter`, 1305
  `:overloaded_error`, 1261 (prompt too long) `:context_overflow`, and the
  plan and usage limits, 1308 to 1321, a `:quota_error` that isn't retried.
  1301 and 1261 were a plain `:http_error`, and 1305 and most usage limits a
  retryable `:rate_limit_error`.
- OpenAI's spend and usage limits (`credit_balance_exhausted`,
  `organization_spend_limit_exceeded`, `project_spend_limit_exceeded`,
  `organization_usage_limit_exceeded`) are `:billing_exhausted` and aren't
  retried.
- A Gemini 429 (`RESOURCE_EXHAUSTED`) whose message names a token limit, such
  as a per-minute input-token quota, is a retryable `:http_error`. It counted
  as a `:context_overflow`, which `OverflowRecovery` handles as a prompt
  that's too long; only a 400 is one.
- `Google.Client` functions, and so a Google model's calls, use a per-call
  `:api_key`, `:transport` and `:transport_opts` over the client's own, like
  the other providers; they were ignored.
- OpenAI Chat Completions requests carry one output cap. A model created
  with `max_completion_tokens:` sent it as both `max_tokens` and
  `max_completion_tokens` on models such as `gpt-4.1`, because
  `ChatCompletionsModel.new/1` copied it into `max_tokens` (it no longer
  does). A request now sends the call's cap, else the model's: as
  `max_completion_tokens` on GPT-5, GPT-6 and o-series models, and under the
  name it was given on others, `max_output_tokens` as
  `max_completion_tokens`. The same holds for xAI's Chat Completions models.
- The `expected` hint for a bare GLM or DeepSeek id names the id you gave,
  such as `"zai:glm-5.3"`, instead of a fixed model.
- The provider registry builds the built-in provider entries (including their
  model profile lists) once instead of on every lookup.
- Requests to an IPv6 address, such as a model server at
  `http://[::1]:8000/v1`, connect instead of failing with `:nxdomain`, through
  `Transport.ReqFinch` (`request/2`, `stream/3` and `stream_reduce/4`) and
  through `Transport.Safe` requests that aren't pinned. They run on an
  isolated connection pool with an IPv6 socket (unless you pass your own
  `:finch`); other hosts still connect as before, on the shared pool. Their
  Host header now carries the port (`[::1]:8000`), which Req left out.
- A response whose headers pass the `max_header_list_size` of
  `Transport.ReqFinch`'s `:mint_connect_options`, which `Transport.Safe` sets
  from `:max_response_header_bytes`, fails with `:response_headers_too_large`
  instead of `:transport_failure`.
- Agents on xAI reasoning models, such as `xai:grok-4.20-0309-reasoning`,
  keep their reasoning between turns. BeamWeaver sent back only the reasoning
  summary, which xAI drops, so the model lost its earlier thinking after every
  tool call, repeated steps, and could loop until a call limit stopped it.
  It now asks for the encrypted reasoning, keeps it in the reply's reasoning
  blocks, and sends it back unchanged (with `store: false` as well).
- A file part with a nested `file` map, as Z.ai and OpenAI Chat Completions
  write it (`%{"type" => "file", "file" => %{"file_url" => url}}`), becomes a
  file block with that URL; the URL used to be dropped, so Z.ai rejected the
  block. Z.ai's older `%{"type" => "file_url", "file_url" => %{"url" => url}}`
  part is read the same way. A data URL gives the block its base64 payload
  and media type, in `"file_data"` (where it used to be sent wrapped in a
  second data URL) and where the part takes a URL (`"file_url"` or `"url"`
  in its `file` map, or Z.ai's `file_url` part, where it used to become a
  URL with no media type).
- A message map whose `metadata`, `response_metadata` or `usage_metadata`
  isn't a map, or whose `server_tool_calls` or `server_tool_results` isn't a
  list, is an `:invalid_message` error from `Core.Message.from/1`, and one
  whose `tool_calls` isn't a list an `:invalid_tool_call` error. A non-map
  `metadata` next to `refusal` raised `BadMapError`, the other fields were
  accepted although `Message.validate/1` rejects them, and a non-list
  `tool_calls` was dropped.
- `use_previous_response_id: true` works on xAI's Responses API: a call sends
  only the messages after the last reply xAI stored, with that reply's id as
  `previous_response_id`. It used to send the full history every time, since
  only OpenAI's `resp_` ids were recognized. A reply from another provider,
  from xAI's Chat Completions API, or made with `store: false` (which xAI
  can't continue) is sent with the rest of the history instead. Checked
  against the live API.
- Replies streamed from xAI's Responses API with `ChatModel.stream_events/3`
  (as every reply of an agent whose model has `stream: true` is) carry xAI's
  metadata (`provider: :xai`, `model_provider: "xai"`) instead of OpenAI's.
  xAI replies also record their API in `response_metadata.api`
  (`:responses` or `:chat_completions`).
- `use_previous_response_id: true` works on OpenAI models made with
  `init_chat_model/2`: their profiles didn't list it, so every call returned
  `:unsupported_model_param`. A reply made with `store: false` is no longer
  used as `previous_response_id`, since OpenAI doesn't keep it; the whole
  conversation is sent instead.
- A model stream that the provider breaks off with an error after its 200
  response fails the call with that error instead of passing the reply so far
  off as complete. Anthropic sends such a failure, for example an
  `overloaded_error`, as an `error` event, and so do the Responses APIs of
  OpenAI, xAI and DeepSeek; Chat Completions APIs (OpenAI, xAI, Moonshot,
  Z.ai, DeepSeek) and Gemini send a chunk with an `error` object. On
  Anthropic, the Responses APIs, Moonshot, Z.ai and DeepSeek,
  `stream_typed_events/3`, `stream_events/3`, `stream_response/3` and
  streaming agents returned the cut-off reply as a success, and on every
  provider the text stream of `stream/3` just ended. The stream now stops at
  that event, without a `Message` or `Done` event, and the call gets the error
  the same failure gets without streaming, from the HTTP status the provider
  documents for the error's `code` or `type`, so `ModelRetry` retries it, or
  not, as it would without streaming. Rate limits, overloads and server errors
  are retried: an Anthropic `overloaded_error` is a retryable `:http_error`
  with `status: 529`, and an error no provider documents counts as a server
  error (500). Content filters (Kimi's `content_filter`, Z.ai's 1301),
  rejected or invalid requests (OpenAI's `invalid_prompt`, Z.ai's 1214),
  context overflows (OpenAI's `context_length_exceeded` in a Responses API
  `error` event, Z.ai's 1261) and exhausted quotas and spend limits (OpenAI's
  `insufficient_quota`, Z.ai's 1113 and usage limits) aren't. A Gemini error
  keeps its own status, or gets the one its `status` names, such as 400 for
  `INVALID_ARGUMENT`.
- `BeamWeaver.Provider.Outcome.classify/1`, and so the `outcome` of
  `Provider.Response.normalize_execution_result/3`, classifies the ways
  providers document for a reply to end early, whether it was streamed or
  not. A Responses API reply that OpenAI's content filter cut off
  (`status: "incomplete"`, with the `content_filter` reason in
  `incomplete_details`) is `turn_disposition: :filtered`, like a Chat
  Completions reply with the `content_filter` finish reason, and so are
  Gemini's content-filter stops, `RECITATION`, `BLOCKLIST`,
  `PROHIBITED_CONTENT`, `SPII`, `IMAGE_SAFETY`, `IMAGE_PROHIBITED_CONTENT`
  and `IMAGE_RECITATION`, as `SAFETY` was.
  Anthropic's `refusal` stop reason is `:refusal`; Anthropic's and Z.ai's
  `model_context_window_exceeded` and xAI's `max_prompt_tokens` are
  `:context_limit`; and xAI's `max_time_limit`, the time xAI gives a
  response, is `:budget_exhausted`. The incomplete Responses replies were
  `:output_limit`, as if the reply had reached its output cap, and the others
  `:final_output` when the reply had text. A filtered Responses reply keeps
  `remote_status: :incomplete`.
- Gemini replies go back with the thought signature of their text. Gemini 3
  can sign the last text part of an answer, and uses its signatures to keep
  its reasoning across turns; BeamWeaver sent the text of a reply from the
  thread without it. Only a reply restored from its `Provider.Replay`
  projection kept it.
- OpenAI Responses requests send an assistant message's id only when the API
  issued it (`msg_...`). An assistant message built by the app, or added by
  middleware, went with the id the thread gave it, and OpenAI refused the
  request ("Expected an ID that begins with 'msg'").
- Every provider sends an invalid tool call back next to the error the agent
  answers it with: Anthropic as a `tool_use` block (with its arguments when
  they parse to an object), Gemini as a function call, Moonshot and Z.ai as a
  tool call, and OpenAI Responses as a `function_call` item, as OpenAI Chat
  Completions, xAI and DeepSeek already did.
- An OpenAI Responses stream whose item reports a later `output_index` on its
  later events than on its `added` event, as the API does after built-in tool
  calls, gives one output item and one content block. The item came back
  twice, once unfinished, and its first block never finished.
- A replayed OpenAI Responses `function_call` keeps its `namespace` (a tool
  that tool search found), `status` and `async` flag.
- An Anthropic-style image given by URL or file id (`source` of type `"url"`
  or `"file"`) keeps its source. It became an empty image, which the
  Anthropic encoder refused; a source without what its type needs stays an
  unknown block.
- `count_tokens_approximately/2` and OpenAI's token counting count a tool
  given as a module or `%Tool{}` struct by its name, description and
  parameters, as a provider gets it. A struct counted as its `inspect` text
  and a module as its name.
- `Models.ProfileRegistry.fetch(:deepseek, nil)` returns an
  `:unsupported_model` error, as the other providers do, instead of raising
  `FunctionClauseError`.
- `DeepSeek.Client.new/1` derives the beta and Anthropic endpoints from a base
  URL with non-ASCII characters correctly; with two or more it kept part of
  the `/v1` suffix (`https://düüp.test/v/beta`).
- Structured-output parsing reports a truncated answer when only the
  response metadata says so (`finish_reason`, `incomplete_details` or
  `status`). A missing finish reason in the message metadata was read as the
  reason `"nil"`, which stopped the search, so the answer failed as invalid
  JSON instead.

#### Compaction engine

- `Compaction.compact/2` no longer forgets a lane's last compaction when the
  state was built with `State.new/1` and `record_success`, which let
  automatic compaction run again right away.
- The compaction engine's `:rapid_refill` guard never fired, because nothing
  counted ineffective attempts. An `:ineffective_compaction` error now
  carries the lane's state with the attempt recorded in
  `details.anti_thrash`; saved, it pauses automatic compaction until new
  context arrives.

#### Testing

- `Models.init_embeddings("fake:embedding", mode: :random)` passes `mode:` to
  the fake embedding model.
- A replay cassette keeps empty strings, empty lists and lists of integers
  as they are written (an empty string used to become an empty map), and a
  cassette that isn't valid YAML returns `:invalid_cassette` instead of
  raising.

### Documentation

- The guides are rewritten and reorganized. A Quickstart builds a first agent
  without an API key, Concepts explains how agents, graphs and deep agents fit
  together, and each feature has one page. New pages cover testing, caching,
  storage, graph state, memory files and coming from LangChain, and each
  provider page has a model table generated from the model profiles.
- Every Elixir example in the README, the guides and the main module docs runs
  or compiles in the test suite.
- Old page names redirect to their new pages on GitBook and HexDocs.
- The examples call their tools and check that they did.
- The deep agent examples that failed on some providers say which tool does
  the work and why: `better_harness.exs` (the evals read `/prompt.txt` from
  disk), `downloading_agents.exs` (drafts are collected from `/drafts`),
  `llm_wiki.exs` (people read the pages), `ralph_mode.exs` (one save ends a
  run) and `deep_agent_composition.exs` (only the writer subagent knows the
  facts).
- When an example's tool check fails, it prints the conversation, one line per
  message, before raising.
- New `examples/zai_media.exs` sends an image, a PDF and a video to
  GLM-5.3-Flash; `mix examples.live --provider zai` runs it.
- `examples/support.exs` sets `reasoning_effort: "low"` only on Z.ai models
  whose profile takes it, so `mix examples.live --model zai:glm-5.1` (and
  GLM-5, GLM-4.7, GLM-4.6) runs the examples; every script used to fail with
  `:unsupported_model_param`.
- `mix examples.live` runs a script once more, after 15 seconds, when it
  failed on a provider's temporary capacity error (an HTTP 429 or 5xx error
  marked retryable); failures of the example itself are never retried.
  `content_builder_agent.exs` says that only posts saved under `/posts` are
  published and that the agent calls `generate_cover` itself.
- Examples that summarize their conversation check tool use through a
  recording middleware (`Support.tool_log/0` in `examples/support.exs`), so a
  summary can't hide the calls, and the live examples allow a model call 120
  seconds.
- Guardrails has a recipe for a reply a content filter stopped, which
  OpenAI's APIs end early as a normal completion: an `after_model/3` hook
  checks `Outcome.classify(reply).turn_disposition == :filtered`, asks the
  model once more, and then fails the call with a `:content_filter` error.
- The Anthropic, OpenAI and xAI provider pages describe `metadata`, the
  provider's request field, with its limits, and point to `trace_metadata:`
  for trace data; the xAI page says xAI takes no request metadata. Models
  says which stream errors count as server errors and when BeamWeaver logs a
  warning about one.
- Subgraphs shows how to edit what a paused subgraph sees: pass its namespace
  from the thread's history as `checkpoint_ns` to `Compiled.update_state/4`
  on the parent graph.
- Tracing lists the `[:beam_weaver, :provider, :unsupported_feature]`
  telemetry event.

## 0.1.32 - 2026-10-08

### Added

- Added `anthropic:claude-haiku-5-5` and `anthropic:claude-sonnet-5-5` profiles
  with 1M-token context windows, 128K output limits, text/image/PDF input,
  adaptive thinking, structured output, tools, streaming, and current cache
  and batch pricing. Haiku defaults to `medium` effort and costs $0.10 input /
  $0.50 output per million tokens for prompts up to 100K tokens; longer prompts
  cost $0.50 / $2.50. Sonnet defaults to `high` and costs $2 / $10, with the
  October 7 cache-read reduction to $0.10 per million tokens.

### Changed

- Sonnet 5.5 accepts `between_tools`
  thinking through `high` effort and rejects disabled thinking and forced
  tools. Haiku 5.5 accepts disabled thinking through `high` effort and preserves
  forced tool choice with adaptive thinking. Both reject manual thinking
  budgets, non-default sampling, assistant prefills, and legacy computer tools.
  Reduced thinking rejects per-turn effort changes; Sonnet rejects advisor
  pairings removed in 5.5.
- Thinking `display: :updates` now infers its required beta header.

### Fixed

- Usage cost estimates select Haiku 5.5's higher prompt-length tier above 100K
  total input tokens, including cache reads and writes, for every token category.
- Anthropic toolset member calls retain `toolset_name` when decoded and replayed.

## 0.1.31 - 2026-09-30

### Added

- Added `openai:gpt-6.1-sol` with a 1.05M-token context window,
  922K input and 128K output limits, text and image input, Responses tools,
  streaming, structured output, and current cache and processing-tier pricing.
  Standard short-context prices per million tokens are $2 input, $0.10 cached
  input, $2.50 cache write, and $10 output.

### Changed

- GPT-6.1 Sol defaults to Responses and rejects `none`/`minimal` reasoning,
  sampling and logprob controls, and Chat Completions tools before transport.

## 0.1.30 - 2026-09-29

### Changed

- The WeaveScope exporter now buffers 100,000 events and uploads byte-bounded
  batches concurrently without doing HTTP work in the queue process. Producers
  backpressure only if the buffer fills, instead of silently dropping older
  events. Queue statistics expose in-flight batches, waiting producers, and
  dead-letter counts; terminal upload failures are logged.
- OpenAI hosted web search summaries retain the billable search action type
  and infer request counts from completed search actions when provider usage
  omits the count.
- Normalized provider responses retain Claude web-search counts and xAI
  server-side tool counters for downstream billing and tracing.
- Z.ai cost estimates use the response model and its effective pricing date,
  including an executed web search, instead of always using GLM-5.2 rates.
- Kimi Chat Completions and streaming responses retain cache-write tokens and
  the provider's 5-minute/1-hour write split from response headers.
- DeepSeek V4 Pro retains its own peak/off-peak pricing after September 14;
  the announced fallback to Flash did not take effect.

## 0.1.29 - 2026-09-23

### Added

- Refreshed OpenAI Responses against the September 23 OpenAPI snapshot:
  `access_programs` is a first-class request field and effective response
  metadata, and prompt-cache prewarming passes through the current nested
  options shape.
- Refreshed Anthropic Messages and token counting against the September 23 API
  reference and generated types: on-demand signed compaction and replay, inline
  tool definitions, MCP tool-listing replay, and workspace selection headers.
- Added live examples for GPT-6 Luna access-program selection and cache
  prewarming, and Claude Opus 5.5 signed compaction, replay, and inline tools.
- Added first-class OpenAI `gpt-6-sol` and `gpt-6-luna` profiles with 1.05M-token
  context windows, 128K output limits, text and image input, `none` through
  `max` reasoning efforts, and current Standard, Batch, Flex, Fast, cache, and
  long-context pricing. Their standard short-context input/output prices per
  million tokens are $2/$10 and $0.10/$0.50, respectively.
- Added Anthropic `claude-opus-5-5` with a 1M-token context window, 128K output
  limit, `medium` default effort, always-on adaptive thinking, and current
  Standard, Batch, Fast, and cache pricing. Standard input/output prices are
  $4/$20 per million tokens.

### Changed

- GPT-6 Sol and Luna default to Responses. Chat Completions function tools
  require `reasoning_effort: :none`; unsupported reasoning and sampling options
  fail before transport. Opus 5.5 rejects disabled or manual-budget thinking,
  forced tool choice, and legacy computer-use declarations on the Claude API.

### Fixed

- Anthropic compaction responses now expose the billed iteration tokens even
  though their top-level usage counters are zero; signed summaries retain their
  required beta header when replayed.
- OpenAI request policy now treats an unspecified reasoning effort as absent
  when validating GPT-6 models, allowing their default-effort requests.

## 0.1.28 - 2026-09-21

### Added

- TypeSafe Jev as a first-class decision model: Choice, Score, and Noul questions,
  provider discovery and profiles, Runnable composition, batch/async calls,
  caching, rate limiting, typed serialization, tracing, and usage/cost metadata.
- `TypeSafeModelRouter` middleware selects a chat model once per run, with
  confidence-gated fallback, resumable route state, and classifier accounting.

### Fixed

- Google typed streaming now emits one normalized assistant message before
  completion, preserving tool calls, usage, finish metadata, response-header
  metadata, and thought signatures from the same streaming request. Agents
  execute streamed tool calls and retain their results for subsequent turns,
  including repeated calls without provider IDs. Provider, transport, malformed
  SSE, and incomplete-stream errors prevent a successful final message.

## 0.1.27 - 2026-09-18

### Changed

- `use BeamWeaver.Tool` generates an input schema with string property names
  and `required` entries, like a hand-written JSON schema. A model sends its
  arguments as a JSON object, and a schema default arrives under the schema's
  property name, so `invoke/3` now receives every field of the `schema` block
  under a string key, defaults included (`input["limit"]`). Before, a default
  arrived under an atom key next to the model's string keys, and a tool had to
  read each field under both. Injected arguments keep their atom names
  (`input.context`), and a direct `Tool.invoke/3` call still passes the
  caller's keys through. Breaking for a module tool that reads a default
  through an atom key (`Map.get(input, :limit, 10)`) or looks up the properties
  of `input_schema/1` by atom.
- Long-term memory is documented as two separate forms, each with complete
  code. Memory files are plain Markdown files on disk: `memory` loads them into
  the system prompt, `BeamWeaver.Filesystem.Local` serves them to the file
  tools, and the application reads and writes them with `File`. Memory records
  are items in a `BeamWeaver.Memory` store (`BeamWeaver.Memory.ETS`,
  `BeamWeaver.Memory.Ecto`): tools with the store and the run context injected
  create, replace, and delete them, a prompt function loads them into the
  system prompt, and the application works on the same records with
  `BeamWeaver.Memory`. The guides no longer keep memory files inside a store
  through `BeamWeaver.Filesystem.Store`. Both forms are covered by agent-level
  tests, records on ETS and on PostgreSQL.
- The memory guides explain how the memory of different owners is kept apart
  inside one application. For records: one namespace per user, project,
  organization, or agent, built from the run context and never from model
  input; how `search/3`, `list_namespaces/2`, and `yield_keys/3` match
  namespace prefixes, and the leak caused by a namespace that is a prefix of
  another owner's namespace; stable and generated keys; filters; deleting
  everything an owner has. For files: one directory per owner, shared files
  made read-only with filesystem permissions, and one module-defined agent that
  serves every user from that user's own directory.

### Fixed

- Long-term memory guide: the guide named the wrong reserved namespace root; it
  is `"beam_weaver"`. `store BeamWeaver.Memory.ETS.new()` in an agent module is
  evaluated for every run and starts each run with an empty store; the guide
  now creates the ETS store once and passes it with `store:`. The search
  example used a `query:` that matches nothing without an index.
- Tools guide: the store example matched `BeamWeaver.Memory.put/5` against
  `:ok` and took the user id from model input.
- Custom filesystem and sandbox examples in the guides call
  `use BeamWeaver.Filesystem`, `use BeamWeaver.Filesystem.Executable`, and
  `use BeamWeaver.Sandbox`. With `@behaviour` alone the struct has no protocol
  implementation and every call raises `protocol ... not implemented`.
- Module tool examples in the guides read their fields under string keys
  (`input["query"]`). `input.query` raised inside an agent, and
  `Map.get(input, :limit, 10)` ignored a limit the model had sent.

## 0.1.26 - 2026-09-17

### Fixed

- Structured-output validation accepts `null` for a required property whose
  type allows it (`"type": ["object", "null"]`, the rendering of an explicitly
  nullable field). 0.1.24 rejected every null under a required key while
  fixing optional nullables, so a model answering "unknown" for such a field
  failed the whole response, whichever model was used.

## 0.1.25 - 2026-09-17

### Fixed

- `BeamWeaver.PromptCache.key/4` never exceeds 64 bytes. OpenAI rejects a
  longer `prompt_cache_key` with a 400, and the prompt-caching middleware's
  default scope is the agent's graph name, so an agent with a name of 14
  characters or more (a 19-character name gave 69 bytes) failed every call on
  that provider. A key over the limit now collapses its scope, model and
  prompt digest into one hash behind the `bwpc:<version>:h:` prefix.

## 0.1.24 - 2026-09-16

### Changed

- Agents with tools and a provider response schema make one call chain instead of
  two when the model profile declares `structured_output_with_tools`: the schema
  stays on the tool-loop calls, tool-call turns pass through it, and the final
  message is parsed against it. Every OpenAI profile now declares the capability
  (OpenAI Structured Outputs work alongside function calling); Anthropic already
  did. Providers without it keep the separate structured-response call after the
  tool loop, and that call now carries the prompt-caching middleware so it no
  longer pays the uncached price for a context the tool loop just cached. The
  provider-level parser passes a tool-call turn through unparsed, since with the
  schema on the loop the structured answer arrives on a later turn.

### Fixed

- `response_schema/2` with `strategy: :auto` (the default) dropped the declared
  `name`, `description` and `strict` options, so provider structured outputs ran
  without strict schema adherence: OpenAI received `"strict": null` and could
  return objects missing required keys. The auto strategy now carries the
  declaration into the provider or tool strategy it resolves to, and an
  unspecified strictness renders as `strict: true` on the wire; only an explicit
  `strict: false` opts out.
- Structured-output validation accepts a null for an optional property. Strict
  provider schemas render optional properties as nullable, so a model answers
  "no value" with `null`; the validator rejected that as a type error, failed
  every such response, and the retry feedback coaxed a minimal answer out of the
  model. The parsed response now carries the property as absent.

## 0.1.23 - 2026-09-10

### Added

- Todo items can retain bounded application-owned `intent` data as part of
  their immutable definition. Revisions preserve it, and hashes include it
  when present while retaining compatibility with existing v1 items.
- `Todo.handoff/4` transfers nonterminal assignments at an application-verified
  ownership boundary while preserving intent, progress, and prior evidence.
- DeepSeek V4.1 Flash is available as `deepseek:deepseek-flash` and is the
  default DeepSeek model. Legacy Flash and Vision IDs remain compatible with
  the new model. Flash supports native image inputs on Chat and Responses,
  uploaded image references, and image-bearing tool results.

### Fixed

- OpenAI Responses typed streams now emit the complete terminal assistant message
  before `Done`, preserving distinct function item and call IDs, reasoning, usage,
  and response metadata for subsequent tool-result turns. Agents publish that
  message once after model processing while retaining incremental token events.
- Req/Finch keeps JSON HTTP error bodies as bytes for provider decoding, preserving
  HTTP status and provider error details instead of failing in `byte_size/1`.
- Added HTTP-backed streaming agent/tool round-trip and JSON error regressions,
  plus offline examples and an optional live OpenAI round-trip check.
- DeepSeek typed streams retain complete reasoning, tool calls, usage, and
  provider metadata across agent tool-result turns. Responses replay preserves
  the opaque reasoning handles returned by the live API.
- DeepSeek cost estimates use weekday-only peak windows and dated rates,
  including the September 10 Flash reduction and September 14 Pro billing
  transition. Historical replay fixtures retain a fixed pricing reference time.
- Transport dispatch loads modules before detecting optional streaming callbacks,
  so the first request does not accidentally fall back to buffered delivery.

## 0.1.22 - 2026-09-04

### Added

- Added first-class OpenAI `gpt-6-astra` support with its 1.05M-token context
  window, 128K output limit, `low`-through-`max` reasoning efforts, Responses
  tool calling, prompt caching, current Standard/Batch/Flex/Fast pricing, and
  documented Trusted Access rollout status.
- Refreshed OpenAI OpenAPI 3.1 response handling with prompt-cache diagnostics,
  Chat Completions response metadata, audio/image/text token breakdowns,
  function-output names and namespaces, moderated-response metadata, detailed
  partial-image frames, and typed shell-output stream events. Both current text
  APIs now accept OpenAI's first-class `moderation` request configuration.
- Refreshed the Anthropic Messages contract against the September 1 OpenAPI
  snapshot: added fallback-credit retries, current web/code tool revisions,
  browser and computer toolsets, and per-message system clearing/effort.

### Changed

- OpenAI request policy now prefers Responses for Astra, maps Chat Completions
  output limits correctly, and rejects Astra's unsupported reasoning,
  sampling, logprob, and Chat Completions tool parameters before transport.
- OpenAI model profiles no longer advertise `audio`, `modalities`,
  `frequency_penalty`, or `seed` as top-level Responses API parameters; those
  fields are absent from the current official `/responses` request schema.
- Anthropic user-profile attribution now uses the required request header, and
  automatic beta selection follows the current advisor, profile, fallback,
  system-message, MCP, and computer-use identifiers without obsolete tool
  betas.

### Fixed

- Anthropic streaming now retains refusal `stop_details`, cache diagnostics,
  and final input-transformation overrides. Response normalization exposes
  context-management, fallback-credit, per-iteration, speed, and server-tool
  usage metadata for observability.

## 0.1.21 - 2026-09-02

### Added

- Added first-class Google `gemini-3.8-flash` support with its 1,048,576-token
  input limit, 65,536-token output limit, multimodal inputs, current thinking
  and built-in-tool capabilities, and introductory standard, cache, batch,
  flex, and priority pricing through December 31, 2026.

## 0.1.20 - 2026-09-02

### Added
- Added first-class Anthropic `claude-fable-5-1` and invite-only
  `claude-mythos-5-1` profiles with 1M-token context windows, 128K output
  limits, full effort ladders, current standard/cache/batch pricing, and
  512-token prompt-cache minimums.
- Fable 5.1 and Mythos 5.1 requests now enforce always-on adaptive thinking
  and reject forced `:any` or named tool choices and final assistant prefills
  before both Messages and count-tokens transport; `:auto` and `:none` remain
  supported. Thinking binding controls infer their required beta header, and
  per-call Anthropic model overrides now resolve the effective profile before
  capability validation, dispatch, tracing, and response normalization.
- Added same-epoch reported-usage delta accounting to `BeamWeaver.ContextBudget`
  and application-owned compaction. A compatible v2 baseline charges only
  changed exact components and append-only component suffixes. Changed,
  shortened, or reordered components are charged in full, while malformed or
  legacy evidence falls back to whole-request accounting.
- Anthropic serialization now preserves whitelisted `cache_control` metadata on
  typed text, plain-text, image, and file blocks, allowing applications to place
  an explicit cache boundary without converting typed content back to maps.

### Fixed

- Built-in summarization, compact-conversation, and local context-editing
  middleware now remove carried reasoning and redacted-thinking blocks whenever
  they rewrite prior history, preventing prefix-bound blocks from being replayed
  against a different conversation prefix.
- Anthropic typed streaming now assembles indexed thinking fragments and their
  signature across arbitrary transport batches into one provider-faithful block
  before agent persistence, so signed Claude 5.1 thinking can be replayed
  unchanged on the next turn. Stateful SSE parsing also keeps fragmented tool
  input associated with its opening tool block.
- Anthropic request extension maps can no longer overwrite provider-owned
  fields after validation, string-keyed custom profile metadata applies the
  same model restrictions, and malformed thinking binding shapes now fail with
  tagged errors instead of reaching transport.

## 0.1.19 - 2026-08-28

### Added

- Added first-class DeepSeek `deepseek-v4-flash-vision-exp` support with image
  inputs on Chat Completions and Responses, including documented image limits,
  formats, detail levels, and current Flash pricing.
- Added Google `gemini-3.1-flash-lite` with multimodal inputs, thinking, tools,
  structured output, and current standard, cache, batch, flex, priority, audio,
  and cache-storage pricing.
- Added Z.ai `glm-5.3` and multimodal `glm-5.3-flash` profiles with supported
  reasoning controls, current standard pricing, and Flash promotional and
  regular pricing metadata.

### Changed

- Rechecked the supported provider catalog and refreshed OpenAI GPT-5.x and
  embedding pricing, context windows, API availability, reasoning controls,
  and multimodal capability metadata.
- Updated Google Gemini pricing and computer-use availability, Anthropic model
  pricing and Claude Opus 4.1 retirement handling, xAI reasoning and
  long-context pricing, and Moonshot pricing provenance.
- Stable Gemini 2.5 Pro, Flash, and Flash-Lite identifiers remain available;
  retired preview variants continue to return replacement guidance.
- GPT-5.6 Sol now uses its promotional standard and cached-input rates through
  November 21, 2026 while retaining regular and long-context pricing metadata.

### Fixed

- Anthropic exact-request streaming now dispatches persisted request bytes
  unchanged. Provider-native replay rejects mismatched bindings before
  materializing content, and Anthropic fallback boundary blocks retain their
  provider payload when replayed.
- Strict checkpoint resume delivery remains idempotent after later checkpoints
  advance the lane head, returning the original verified receipt without
  disturbing unrelated pending writes.
- Compaction now applies compatible provider-usage floors only to the original
  request they measured, rejects malformed focus values and duplicate lane
  ordinals, and validates shared-window output reservations before calculating
  the input limit.
- Safe transport errors after delegate dispatch remain classified as unknown
  outcomes even when the delegate reports pre-dispatch metadata, and pinned
  IPv6 requests emit a correctly bracketed Host authority.
- Docker durable exec now requires an already-started container, while
  label-qualified cleanup rejects empty or malformed ownership identities
  before Docker I/O.
- Codex Responses request normalization now canonicalizes controlled atom and
  string keys without emitting duplicate wire parameters, and skill
  frontmatter rejects duplicate keys at nested YAML levels.

## 0.1.18 - 2026-08-15

### Added
- Added provider-neutral `BeamWeaver.ContextBudget` and
  `BeamWeaver.Compaction` primitives for applications that own durable
  conversation checkpoints, activation, and recovery. The portable engine
  provides bounded safe-tail selection, deterministic tool projection,
  cumulative semantic summaries, one schema repair, effectiveness checks, and
  lane-local anti-thrash state without adding a process or persistence layer.
- Added `BeamWeaver.Models.UsageCost.calculate_usd_micros/2` for exact,
  integer-only pricing with explicit dimensions and one final rounding rule.
- Docker sandboxes accept explicit bind mounts, resource limits, read-only root
  filesystems, dropped capabilities, security options, and tmpfs mounts, and
  expose `BeamWeaver.Sandbox.Docker.stop/1` for application-owned cleanup.
- Added error-preserving `BeamWeaver.Checkpoint.fetch_tuple/2` and
  `list_result/3`, all-or-nothing `put_many/3`, and bounded lineage
  `fork_at/4` APIs while retaining the existing convenience facades.
- Added bounded provider response validation and the batch-atomic, sticky
  `BeamWeaver.Provider.StreamValidator` used by live provider streams.
- Added cooperative cancellation, bounded subscriber delivery, and explicit
  work timeouts to the supervised agent runtime, plus the policy-neutral
  `BeamWeaver.DispatchHook` for application checks immediately before model or
  tool attempts.
- Runtime agents may monitor an optional application owner and terminate all
  active supervised work when that owner exits.
- Live stream producers stop when their consuming work process exits.
- Added immutable `BeamWeaver.Todo` revisions with stable IDs, bounded DAG
  validation, evidence-bearing transitions, and deterministic hashes.
- Added the optional `BeamWeaver.Agent.Subagent.Host` boundary for applications
  that own durable child admission and result delivery.

### Changed
- Tool input validation can return a normalized string-keyed map and now
  enforces declared closed properties, string and numeric bounds, collection
  limits, nested schemas, and normalized-key collision rejection.
- URL allowlists now narrow destinations without bypassing private, metadata,
  or reserved-address checks. `Transport.Safe` can pin a request to one
  validated DNS result while retaining the original Host and TLS identity, and
  the Req/Finch streaming path enforces its response-byte ceiling.
- Checkpoint latest/history/pruning/fork selection now uses a persisted
  per-thread, per-namespace commit order instead of interpreting checkpoint IDs
  as timestamps. Existing explicit and legacy IDs remain unchanged.
- Atomic checkpoint-plus-write and batch operations now fail before writing
  when an adapter does not implement the required transaction callback; they
  never fall back to sequential partial writes.
- Host-managed subagents use only explicit descriptors and typed host results;
  they do not invoke nested runners, copy parent state, or use the legacy child
  result cache.

### Fixed

- Compaction policy, state, event, and semantic constructors now reject atom
  and string keys that normalize to the same closed field.
- Supervised model work now preserves a typed `BeamWeaver.Core.Error` when it
  crosses the runtime boundary, allowing an application to distinguish a
  provider context overflow from an ordinary execution failure.
- Checkpoint storage failures are no longer converted into missing checkpoints
  or empty histories at public runtime boundaries.
- Adapter structs now load their module before callback discovery, so a valid
  application adapter is not rejected on its first invocation.

## 0.1.17 - 2026-08-13

### Added

- Added the first-class `google:gemini-3.7-flash` profile with its 1,048,576
  input-token and 65,536 output-token limits, multimodal inputs, text output,
  `low`/`medium`/`high` thinking levels, Gemini built-in tools, structured
  output, and introductory standard/cache/batch/flex/priority pricing.
- Added optional SQLite checkpoint persistence through
  `BeamWeaver.Checkpoint.Ecto`. Applications opt in by adding `ecto_sqlite3`;
  BeamWeaver declares it as an optional dependency.

### Changed

- Updated DeepSeek V4 Flash and Pro model versions and pricing to the August 13
  catalog. Cost calculation now applies the provider's UTC peak windows using
  the response timestamp and defaults to off-peak prices when no timestamp is
  available.
- Replaced PostgreSQL-specific checkpoint read/write SQL with one shared Ecto
  query layer for PostgreSQL and SQLite. Only migrations and transaction
  serialization remain adapter-specific.

## 0.1.16 - 2026-08-13

### Added

- Enabled DeepSeek V4 Pro on the Responses API following DeepSeek's August 12
  compatibility update, including model profiles, request validation, live
  capture coverage, and the newly documented `minimal` reasoning effort.
- Added xAI `grok-4.6` as the default Grok model for Responses and Chat
  Completions, with its 500k context window, unlimited text-output metadata,
  full reasoning-effort ladder, priority processing, and standard and
  long-context pricing. Refreshed Grok 4.5 cached-token pricing and reasoning
  metadata from the same current catalog.

## 0.1.15 - 2026-08-02

### Added

- Added first-class DeepSeek V4 Flash and Pro support across Chat Completions,
  beta prefix/strict tools, Responses, FIM, model listing, balance, and the
  Anthropic-compatible Messages endpoint, with lazy streaming, normalized
  reasoning/cache usage, current pricing, and live conformance coverage.

### Fixed

- Updated named Finch pool options for Req 0.7 so synchronous and streaming
  requests no longer emit the deprecated `finch: name` warning.
- Updated the shared Ecto adapter to use `Repo.transact/1`, preserving its
  existing result contract without invoking Ecto's deprecated transaction API.
- Synchronized shell timeout cleanup with stderr initialization so timed-out
  host and session commands no longer emit missing-scratch-file warnings or
  leave scratch directories and Port messages behind.
- Made record-manager key pagination deterministic when records share a
  timestamp, matching the Postgres adapter's timestamp-and-ID ordering.
- Updated GPT-5.6 Terra and Luna pricing metadata to OpenAI's July 30 rates,
  added current Batch/Flex/Fast multipliers, and documented Fast mode's
  backward-compatible `priority` service-tier alias.

## 0.1.14 - 2026-07-20

### Added

- Added first-class Anthropic `claude-opus-5` support with its 1M-token
  context window, 128K output limit, current standard/cache/batch/fast pricing,
  full effort ladder, default adaptive thinking, 512-token prompt-cache
  minimum, server-side fallbacks, and mid-conversation system/tool changes.
- Opus 5 requests now reject disabled thinking at `xhigh` or `max` effort and
  reject the unsupported Anthropic web-fetch server tool before transport.
  Anthropic fallback boundary blocks are preserved when assistant turns are
  replayed.
- Added Google Gemini 3.6 Flash and Gemini 3.5 Flash-Lite profiles with
  multimodal input, thinking, tool, structured-output, inference-tier, token
  limit, model-specific parameter and final-turn validation, and current
  standard/cache/batch/flex/priority pricing metadata.
- Gemini 3.5 Flash Cyber now returns an explicit limited-access error instead
  of being accepted by the permissive Gemini family fallback; Google exposes
  it only to governments and trusted partners through CodeMender, not through
  the public Gemini Developer API.

### Fixed

- Anthropic server-tool declarations now include their required wire names,
  the GA `code_execution_20260120` tool no longer sends a retired beta header,
  mid-conversation tool changes use typed tool references, and typed PDF blocks
  preserve URL sources.

## 0.1.13 - 2026-07-20

### Fixed

- `BeamWeaver.Schema` now resolves primitive field types, nested schema modules,
  and compound literal types such as `{:array, MySchema}` into their complete
  JSON Schema definitions on current Elixir releases.

## 0.1.12 - 2026-07-18

### Added

- Added Moonshot `kimi-k3` support with 1,048,576-token contex and output 
  limits, current cache/input/output pricing metadata, top-level
  `reasoning_effort: "max"`, `tool_choice: "required"`, and K3-only dynamic
  tool-loading messages through `BeamWeaver.Moonshot.Tools.dynamic_message/1`.

### Fixed

- Moonshot stream reconstruction now reads usage from Kimi's documented final
  `choices[0].usage` shape as well as the older top-level usage shape.

## 0.1.11 - 2026-07-08

### Added

- Added first-class OpenAI GPT-5.6 Sol, Terra, and Luna profiles plus the
  official `gpt-5.6` alias, including 1.05M context limits, reasoning modes,
  provider capability metadata, and standard/cache/long-context pricing data.
- Added GPT-5.6 `prompt_cache_options`, explicit content-block cache
  breakpoints, Responses file detail, cache-write usage normalization, and
  persisted reasoning-context metadata for OpenAI requests and responses.
  Responses models now also accept `safety_identifier` as a model-level option.

### Changed

- GPT-5.6 models now prefer the Responses API, and Chat Completions rejects
  function-tool requests before transport unless reasoning effort is `none`.

### Fixed

- OpenAI cache-write usage now populates canonical `cache_creation_tokens`, and
  response-level service tier/region metadata now reaches model traces and
  WeaveScope event fields instead of remaining only in raw provider metadata.

## 0.1.10 - 2026-07-08

### Added

- Added `BeamWeaver.Core.ChatModel.stream_typed_events/3` and
  `async_stream_typed_events/3` for standalone chat-model callers that need
  normalized BeamWeaver stream envelopes without relying on provider-specific
  lifecycle event APIs.

### Changed

- Added xAI `grok-4.5` as the default Grok chat profile with 500k context,
  multimodal input capability metadata, configurable reasoning metadata, current
  token pricing, and documented latest aliases.
- Agent model nodes now use typed request-level streaming when `stream: true`
  is present and the provider supports typed events, forwarding live model
  reasoning chunks through graph and agent streams while keeping the final
  assistant message reconstructed from visible answer/tool chunks.

### Fixed

- OpenAI-compatible Responses streaming now recognizes xAI
  `response.reasoning_text.delta` and `response.reasoning_text.done` events
  alongside OpenAI reasoning-summary events, so Grok reasoning can surface as
  live `%BeamWeaver.Stream.Events.MessageChunk{}` reasoning blocks.
- Reasoning stream chunks are now emitted as
  `%BeamWeaver.Core.ContentBlock.Reasoning{}` instead of generic text-bearing
  maps, preventing reasoning deltas from being folded into assistant answer
  text by message projection or streamed final-response reconstruction.
- Agent streaming falls back to the existing `stream_response/3` path when a
  provider reports typed stream events as unsupported, preserving existing
  streaming behavior for providers that have not added typed event support.

## 0.1.9 - 2026-07-04

### Fixed

- Vector-store metadata filters now bind JSON path segments as query
  parameters, preventing metadata filter keys from being interpolated into raw
  Postgres SQL while preserving nested metadata lookup support.
- Local sandbox file operations now resolve symlinks before containment checks,
  blocking reads, writes, listings, globs, and recursive grep matches that
  would escape the sandbox root through symlinked paths.
- Shell policy string allow rules now require a command boundary and reject
  unquoted shell chaining or command substitution, so an allowed prefix cannot
  authorize `allowed_cmd; malicious_cmd`.
- Local sandbox command execution now streams stdout/stderr into a bounded
  buffer controlled by `max_output_bytes` and marks oversized output as
  truncated instead of accumulating unbounded command output in memory.
- Recursive text splitting now rejoins chunks with the separator that actually
  split each level, preserving source whitespace and valid `add_start_index`
  metadata for word-level splits.
- OpenAI chat message conversion now deduplicates assistant tool calls by
  request id when the same call is present in both `tool_calls` and content
  blocks, avoiding duplicate ids in provider requests.
- Manual graph state updates now compute next tasks through the normal
  scheduler, so conditional and guarded edges route correctly after
  `update_state/4`.
- Subagent stream handles now route child values, updates, and errors only to
  the most specific active subagent handle, preventing nested child events from
  leaking onto ancestor handles.
- Anthropic usage parsing now reports ephemeral 5m/1h prompt-cache writes under
  canonical cache-creation usage, so cost and telemetry accounting no longer
  treat those cache writes as zero.
- Memory full-text queries now search canonical value and metadata text instead
  of Elixir `inspect/1` output, avoiding matches on wrapper field names and
  struct implementation details.
- Stream mux heartbeats now respect finite stream timeouts, so a hung producer
  cannot keep a live stream open forever by emitting heartbeat events.
- PII middleware now redacts assistant tool-call arguments and buffers streamed
  text across chunk boundaries, preventing split PII from bypassing streaming
  redaction.
- Fixed low-severity edge cases in provider and tool adapters: OpenAI nil
  tool-call arguments now encode as `{}`, OpenAI usage totals are inferred when
  omitted, Z.ai streams keep id-less delta chunks, Moonshot rejects unsupported
  audio/file blocks, file search preserves snippet case and counts filename
  matches, tool defaults apply before validation, stream lifecycle routing
  tolerates payload-only message ids, and ETS cache pruning is serialized.
- Partial JSON parsing now repairs truncated JSON in a single capped structural
  pass, avoiding superlinear prefix scans on streamed tool-call arguments.
- Stream/message transforms, Google SSE merging, text-splitter start-index
  tracking, and Z.ai response conversion avoid repeated list appends or
  full-document rescans on streaming hot paths.
- WeaveScope trace export now disables Req's internal retry loop and logs
  failed uploads with BeamWeaver exporter context, so timeout diagnostics point
  at the trace export path instead of only `Req.Steps`.
  

## 0.1.8 - 2026-07-01

### Added

- Added Anthropic `claude-sonnet-5` profile support with adaptive thinking
  effort configuration, Sonnet 5 capability metadata, and validation for manual
  thinking budgets and restricted sampling options.
- Added normalized model tooling metadata that separates user-defined tool
  calls from provider-hosted tools under `response_metadata.tooling.user` and
  `response_metadata.tooling.hosted`, including compact hosted tool summaries
  and OpenAI hosted usage metrics for image generation and web search.
- Added WeaveScope trace detail rendering for user tools, hosted tools, and
  hosted usage as separate sections from provider response headers.
- Refreshed Moonshot/Kimi `kimi-k2.7-code` and
  `kimi-k2.7-code-highspeed` model metadata, including the highspeed variant's
  official pricing source and throughput metadata.  

### Changed

- Normal successful model calls now let each provider client decode its own
  allowlisted response headers into canonical `response_metadata.headers`
  without requiring `include_response_headers`, and use those headers to
  populate request IDs and shared rate-limit summaries where applicable. Raw
  full response headers remain controlled by `include_response_headers` inside
  BeamWeaver and are stripped from WeaveScope export payloads.
- WeaveScope trace export now preserves richer model response metadata,
  including provider response headers, model ids, stop details, nested cache
  usage, thinking token counts, service tier, inference geo, and raw provider
  metadata needed for trace inspection and pricing.
- Google Gemini response decoding now preserves `thoughtSignature` values on
  text and reasoning parts and exposes reasoning/text signatures through
  normalized response metadata.
- WeaveScope trace export now recursively scrubs BeamWeaver debug/raw header
  containers from metadata, inputs, outputs, usage, and error payloads while
  preserving canonical decoded provider headers at `response_metadata.headers`.

### Fixed

- Live stream mux producers now inherit the active tracing context, so nested
  live streams started inside graph nodes remain attached to the parent trace
  instead of creating separate root traces. This keeps streamed final-agent
  responses grouped under the surrounding workflow in WeaveScope.

## 0.1.7 - 2026-06-29

### Added

- Added Agent per-call `model_opts:` overrides for `invoke/3` and
  `stream_events/3`, so provider request options such as `prompt_cache_key`,
  `x_grok_conv_id`, and `reasoning_effort` can be passed through Agent calls
  without leaking internal runtime keys.
- Added provider-aware Agent prompt caching via `prompt_caching true`,
  `prompt_caching scope: ..., version: ...`, and
  `BeamWeaver.Agent.Middleware.PromptCaching`, with generated cache keys for
  OpenAI, xAI/Grok, Moonshot/Kimi, and Anthropic static-system-prompt cache
  control.
- Added `BeamWeaver.PromptCache` for stable cache-key construction across
  examples and application code.

### Changed

- Prompt caching middleware now fills only missing provider cache options;
  explicit model-level or per-call options keep precedence.
- The prompt-caching example now exercises the Agent path instead of direct
  `ChatModel.invoke/3`.

### Fixed

- xAI Responses Agent calls now receive both `prompt_cache_key` and
  `x_grok_conv_id` when prompt caching is enabled, while xAI Chat Completions
  receives the `x-grok-conv-id` routing header.
- Runtime-built agents, module agents, streams, and subgraph invocations now
  preserve per-call model options through the graph runtime.

## 0.1.6 - 2026-06-29

### Changed

- Cleaned user-facing docs to reduce duplicate coverage, clarify provider and
  adapter responsibilities, and keep development-only implementation notes out
  of public guides.

### Fixed

- Z.ai structured-output requests now inject the JSON Schema contract into the
  prompt when BeamWeaver has a schema but the provider request can only enforce
  JSON object mode.
- Structured-output retries now include safe validation details such as missing
  required keys in the retry prompt, making provider retries more likely to
  repair invalid JSON shapes.
- Structured-output result handling now preserves parser error details when
  converting validation failures into BeamWeaver errors or tool feedback.

## 0.1.5 - 2026-06-28

### Added

- Added a dedicated prompt-caching guide and runnable example covering stable
  cache-key construction, provider-specific cache controls, and cache-hit
  inspection across OpenAI, xAI/Grok, Anthropic, Moonshot/Kimi, Gemini, and
  Z.ai.
- Added first-class OpenAI Responses and Chat Completions `prompt_cache_key` and
  `prompt_cache_retention` model options, while keeping per-call overrides.
- Added xAI/Grok cache routing support: Responses accepts `prompt_cache_key`,
  and Chat Completions accepts `x_grok_conv_id`, which BeamWeaver sends as the
  `x-grok-conv-id` header.
- Added prompt-cache example helpers, including `GOOGLE_CACHED_CONTENT` /
  `GEMINI_CACHED_CONTENT` support for externally managed Gemini cached-content
  resources.

### Changed

- Model traces now preserve provider-specific invocation parameters from the
  checked-in profile registry, including cache keys and cache-routing options,
  while still omitting client configuration and secrets.
- Prompt-cache documentation now lives in the main model documentation and
  dedicated guide instead of the custom-middleware page; the prebuilt middleware
  guide points Anthropic static-system-prompt caching to
  `BeamWeaver.Agent.Middleware.PromptCaching`.
- Redaction now keeps token counts and generation limits such as
  `max_output_tokens`, `budget_tokens`, and `*_token_count` fields so cache and
  usage telemetry remain inspectable.

### Fixed

- OpenAI Responses `prompt_cache_key` now respects first-class model options
  ahead of `model_kwargs`, while per-call options continue to take precedence.
- xAI requests now merge per-call headers with default headers and let per-call
  `x_grok_conv_id` override the model-level conversation/cache routing header.

## 0.1.4 - 2026-06-25

### Added

- Added OpenAI Responses `store: false` replay sanitization for cached
  assistant messages. Replay now drops provider-only item IDs, skips
  non-replayable reasoning and empty image-generation blocks, and preserves
  encrypted reasoning content that can safely round-trip.
- Added OpenAI `apply_patch` built-in tool rendering and replay parsing for
  `apply_patch_call` and `apply_patch_call_output` provider items.
- Added an offline OpenAI `apply_patch` example that shows request rendering and
  replayable assistant patch history without requiring live credentials.
- Added replay-backed provider conformance fixtures for OpenAI replay
  sanitization and xAI reasoning request-shape handling.
- Added WeaveScope exporter queue telemetry coverage for retry, flush,
  rejection, and dead-letter paths.
- Added `tool_call_streaming` to model capability profiles and exposed it through
  profile compilation, compatibility checks, and the profile matrix task.
- Added pre-projection message stream transforms, including a PII stream
  redaction helper that edits typed token/message envelopes before projection.
- Added Agent Protocol client hardening for encoded task paths,
  JSON-string/map body normalization, non-2xx error payloads, and async-subagent
  native trace metadata.
- Added a native sandbox provider registry with validated provider specs,
  builtin local provider construction, lifecycle capability checks, and redacted
  provider metadata.
- Added explicit interpreter adapter contracts and a supervised interpreter
  session boundary for adapter-owned eval, snapshot, restore, timeout, cancel,
  and close behavior without adding a default unsafe interpreter runtime.

### Changed

- Anthropic tool-call IDs are now normalized deterministically at the Anthropic
  provider boundary while preserving BeamWeaver's native message and tool-call
  structs.
- xAI reasoning profiles omit unsupported `stop` request parameters while
  non-reasoning xAI chat-completions models continue to send supported stop
  sequences.
- Agent harness offload and model-request metadata now use native keys such as
  `:offloaded_to` and `:source`.
- WeaveScope trace payload tests now assert native BeamWeaver/WeaveScope fields
  for run envelopes, model generation details, tool payloads, usage, lifecycle
  status, event versions, tags, and metadata.
- OpenAI and xAI stream handling now preserves empty initial chunks,
  incremental tool-call arguments, reconstructed final assistant tool calls, and
  detailed usage metadata.
- Summarization triggers now support explicit AND/OR composition with
  `{:all, triggers}` and `{:any, triggers}`.
- Human-in-the-loop middleware now supports predicate-gated review configs and
  `interrupt_mode: :first` for reviewing only the first matching tool call.
- Sandbox and filesystem command execution results now carry additive native
  metadata such as provider ID, sandbox ID, command ID, snapshot ID, reconnect
  count, timeout, exit status, retryability, and raw provider status when the
  backend supplies it.

### Fixed

- Graph task exits, timeouts, and cancellations now preserve the BEAM root cause
  in normalized graph errors and emit native graph telemetry for failure paths.
- Checkpoint serialization tests now guard that only known BeamWeaver tagged
  structs decode, while foreign constructor-shaped maps remain inert data.
- Transport and trace redaction now cover nested bearer tokens, provider keys,
  URL credentials, query-string secrets, env-style assignments, private key
  blocks, and secret headers without redacting token-count usage fields.
- `list_async_tasks` refreshes active async tasks while leaving terminal task
  records cached, so completed/cancelled/error tasks are not re-polled.
- Sandbox execution, remote-provider fakes, interpreter sessions, and shell
  commands now normalize timeout/crash metadata and emit native telemetry while
  redacting credential-shaped fields before tracing.

## 0.1.3 - 2026-06-23

### Added

- Added a first-class Z.ai provider for `zai:glm-5.2`, including runtime
  config from `ZAI_API_KEY`, optional Z.ai base URL overrides, provider/model
  registry entries, model profile metadata, and provider matrix support.
- Added native Z.ai chat-completions support for non-streaming and streaming
  responses, JSON mode, function tools, streamed tool-call argument merging,
  reasoning deltas, request metadata, raw usage, and estimated cost metadata.

## 0.1.2 - 2026-06-20

### Fixed

Security and transport:

- SSRF: Req no longer auto-follows redirects. Every redirect hop is validated
  against the URL policy, including on streaming paths.
- PII: overlapping detector spans (such as a URL containing an IP) no longer
  crash or garble output. Spans are pruned to stay disjoint.
- IPv4 reserved-range checks no longer over-block public `/16` ranges.
- IPv6 `fe80::/10` is treated as reserved, so it stays blocked when
  `allow_metadata?` is on.
- Per-call request options (including `:timeout`) override client transport
  defaults instead of being shadowed.

Providers:

- Anthropic: beta flags go in the `anthropic-beta` header, not the body. This
  covers invoke, stream, stream_events, and count_tokens.
- Anthropic: final streaming usage is a proper usage map merged into metadata.
- Anthropic: a non-list `:tools` option (such as `nil`) no longer raises; tools
  are omitted.
- Google: streaming tolerates chunks with no candidates, content, or parts.
- Google: `countTokens` sends exactly one of `contents` or
  `generateContentRequest`.
- OpenAI: a bare-string `:image_url` block is handled instead of crashing.
- OpenAI: model inference is limited to `o1`/`o3`/`o4`/`chatgpt` prefixes, so
  other models are not misrouted.
- OpenAI: parsing a chunk with no tool calls returns `[]`, not an error.
- xAI: `ChatCompletionsModel.new/1` no longer crashes on `streaming: true`.
- Moonshot: the tool-name regex accepts short and digit/hyphen-leading names.
- Provider runtime: stream-metadata returns `%{}` instead of crashing when an
  adapter has no metadata function.
- Cached models keep usage cost on a cache miss, for both stream and
  stream_events.

Agents and middleware:

- `interrupt_before`/`interrupt_after: :all` is preserved instead of becoming
  `[:all]`, which had disabled all human-in-the-loop interrupts.
- Structured final-response extraction handles string-keyed state instead of
  crashing.
- `list_async_tasks` refreshes live status before filtering, not stale status.
- A configured subagent-output response that is not a map or function is honored,
  not dropped.
- The tool emulator falls back to `"unknown_tool"` when a tool call has no name.

Graph:

- Validation-node task exits become error messages instead of crashing the node.
- Pending checkpoint-map merging tolerates a missing `configurable` key.
- Delta channels keep `nil`/`false` overwrite values instead of resetting to the
  initial value.
- `input_channels` hides private channels (such as `__node_outputs__`) when there
  is no `input_schema`.
- An empty-list edge condition is treated as membership, not a match-anything map.
- `add_messages` honors the last `remove_all` marker, not the first.
- OpenAI message formatting tags tool calls as `"tool_call"`, not `"tool_calls"`.
- `ServerInfo.User` Access no longer leaks struct-field keys into user metadata.

Memory, retrieval, and indexing:

- Ecto memory applies `default_ttl` on write. Refresh-on-read updates only
  `expires_at`, not `updated_at`.
- ETS chat history no longer drops messages under concurrent `add_messages`;
  writes are atomic.
- Indexing without a record manager deduplicates documents that share an id.
- ETS memory namespace listing ignores unknown match-condition types instead of
  crashing.
- Memory metadata filters match a plain-map value by equality instead of always
  failing.
- Vector-store SQL filters render `$and`/`$or`/`$not`.
- The policy retriever honors `:similarity_score` and `score_threshold`.
- The SQL `$like` filter keeps the user pattern verbatim, matching ETS `like`.
- ETS vector store stringifies ids in `delete`/`get_by_ids`, so non-string ids
  match.
- File-search snippets slice with correct offsets, fixing garbled multibyte text.
- `add_start_index` reports a character index, not a byte offset.

Rate limiting:

- The rate-limited wrapper streams through `ChatModel.stream/3` instead of
  degrading to invoke when the provider module is not loaded.
- Token-bucket `acquire` rejects negative or non-integer timeouts and invalid
  modes up front.
- Retry delays are re-clamped to `max_delay` after jitter, including the
  zero-backoff path.

Serialization and schema:

- Maps with colliding atom/string keys raise instead of silently dropping one.
- The pretty JSON encoder escapes all control characters.
- Structured-output `oneOf` variants get distinct spec names.
- A nullable typeless tool field becomes `anyOf[…, null]`, not null-only.
- Checkpoint config normalization returns `%{}` when `configurable` is `nil`.
- `MapAccess.first` returns a `false`/`nil` value instead of the default.
- Empty-string schema defaults are emitted, not dropped.
- Strict tool-schema rendering keeps user keys with `nil` values.
- Schema fields given as 2-tuples normalize instead of crashing.
- Tracing `custom_fields` skips non-pair list entries instead of crashing.

Core messages and text:

- XML output parsing slices on byte offsets, fixing multibyte corruption.
- Tool-result truncation backs off to a valid UTF-8 boundary.
- Trimming with `:last` keeps the last words, not the first.
- Usage subtraction clamps right-only token counts to zero, including nested maps.
- The `drop_oldest` mux drops the newest item instead of erroring when the buffer
  is full.
- Prompt partials and the simple template renderer no longer mishandle supplied
  or brace values.
- Partial JSON repair is no longer cubic on long input.
- Fixed assorted dead and edge-case clauses: agent decision normalization,
  transient-error and MFA retry predicates, and the HTML header splitter.

Sandbox and shell:

- Docker `edit/5` starts the container once and threads it through
  read/write/execute. Edits previously hit throwaway containers and leaked
  containers.
- Docker execute/read truncation respects UTF-8 codepoint boundaries.
- The Docker sandbox prints the entry type before the path, so `ls`/`glob` handle
  paths containing `|`.
- File-formatting long-line chunking splits on character boundaries, not raw
  bytes.
- A host shell command no longer crashes when the policy timeout is `nil`.
- Shell host-executor and session temp files are cleaned up even on timeout or
  kill.

### Changed

- Default operation timeout raised from 5 seconds to 5 minutes for runnable
  `batch`/`map`/`parallel`/fallback and the agent `GenServer.call`. An explicit
  `:timeout` still overrides it.

### Internal

- Removed dead clauses and other compiler-warning sources. `mix compile` and
  `mix test` now run clean.

## 0.1.1 - 2026-06-20

### Added

- Added Moonshot/Kimi profiles for `kimi-k2.7-code`,
  `kimi-k2.7-code-highspeed`, `kimi-k2.6`, and `kimi-k2.5`.
- Added request validation for Kimi thinking, fixed sampling, and tool-choice
  constraints.
- Added an Apache License 2.0 `LICENSE` file.

### Changed

- Updated Moonshot/Kimi docs and install snippets for the `0.1.1` release.
