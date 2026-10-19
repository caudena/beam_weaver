# Changelog

## 1.0.0 - 2026-10-08

This release removes compatibility surfaces that nothing inside BeamWeaver
used, replaces them with plain Elixir, and fixes the problems the
documentation rewrite found. New features come first, each with a link to its
guide. Breaking changes follow, grouped by area with security first, each with
what to do instead. Then come the other security fixes, the other changes, bug
fixes and documentation. Changes and fixes are relative to 0.1.32.

### New features

#### Agents

**Jumps from tools and wrappers.** `BeamWeaver.Agent.jump/2` returns a
command that applies an update and jumps to `:end`, `:model` or `:tools`. See
[Middleware](docs/middleware.md#what-hooks-return).

**Capability profiles.** The `capability_profile` declaration and
`BeamWeaver.Agent.build/1` option apply a profile's prompt, tool and
middleware settings; `:auto` uses the profile of the agent's model. See
[Capability Profiles](docs/profiles.md#apply-a-profile).

**Timeouts on agent and graph modules.** Agent and graph modules declare
`step_timeout`, `run_timeout` and `tool_timeout`, as `build/1` options do.
See [Durable Execution](docs/durable_execution.md#timeouts).

**Structured output that corrects itself.** With the tool strategy, the model
answers again, up to `max_retries` times, when its answer fails the schema.
See [Structured
Output](docs/structured_output.md#validation-errors-and-retries).

**Declarations and context types.** `BeamWeaver.Agent.declarations/1`
returns an agent module's declarations as `build/1` options, and
`context_schema` fields accept `:float`, `:decimal`, date and time types,
`{:list, type}` and `{:union, types}`. See [Agents built at
runtime](docs/agents.md#agents-built-at-runtime).

#### Middleware

**Summarization that recovers.** `Summarization` retries a failed summary
call, cuts down a summary prompt that is over the model's context window, and
takes `summarizer:`, a function that writes the summary, as
`compact_conversation` does; `Summarization.summarize/2` works outside a
run. With automatic summarization on, a call rejected as too long for the
model summarizes the thread and is sent once more. See [Context
Management](docs/context_management.md#recover-from-context-overflow-errors).

**UnsupportedMedia, ToolError and AutoMode.** `UnsupportedMedia`, on every
agent, replaces images and PDFs the called model can't take with a short
notice. `ToolError` decides what the model reads when a tool fails, and
`AutoMode` blocks calls of the tools you name that a decision model finds
risky. See [ToolError](docs/builtin_middleware.md#toolerror) and [Block risky
tool calls](docs/guardrails.md#block-risky-tool-calls).

**ToolSelection, ContextEditing and PII options.** `ToolSelection` retries a
selection reply without a list of tools, `ContextEditing` takes
`token_counter:`, and `PII.stream_transform/1` also redacts streamed
reasoning, tool-call arguments, tool events and state snapshots. See [Redact
a stream](docs/streaming.md#redact-a-stream).

#### Human review and durable runs

**One review per tool call, and every pause of a step.** With
`interrupt_mode: :per_call`, `HumanInTheLoop` pauses each call that needs
review on its own, and a paused run lists every interrupt of its step in
`interrupts`. See [One pause per
call](docs/human_in_the_loop.md#one-pause-per-call).

**Describe and check an answer.** `Graph.interrupt/2` takes
`response_schema:`; a resume value that doesn't match it fails with
`:invalid_resume` and the interrupt waits. See [Check the
answer](docs/human_in_the_loop.md#check-the-answer).

**Review inside subagents.** A subagent that pauses for human review pauses
the parent, and resuming the parent resumes it; the `task` tool used to
return `"Subagent interrupted: ..."`. See
[Subagents](docs/subagents.md#human-review).

**Continue a run where it stopped.** `invoke/2` and `stream_events/2` with an
empty input, and `resume/2`, continue a thread whose last run stopped before
the end instead of starting over. See [Durable
Execution](docs/durable_execution.md#what-survives-a-crash).

#### Subagents and deep agents

**Async subagents know who launched them.** Every
`BeamWeaver.Agent.Protocol.Client` callback gets `parent:` in its opts: the
parent's thread, run, tool call and trace ids. See
[Subagents](docs/subagents.md#async-subagents).

**Subagent options and streams.** `Agent.Subagent.Spec` takes every
`BeamWeaver.Agent.build/1` option, a
`BeamWeaver.Agent.GeneralPurposeSubagentProfile` in a `subagents` list
configures the built-in `general-purpose` subagent, and subagent runs stream
into the parent's stream. See [Declare
subagents](docs/subagents.md#declare-subagents).

#### Graphs and streaming

**Graph modules.** `use BeamWeaver.Graph` turns a module into a graph with
`invoke/2`, `stream_events/2`, `resume/2` and `get_state/1`, and graph and
agent modules run as nodes of other graphs. `Compiled.get_graph/2` reports
`entry_points` and `finish_points`. See
[Graphs](docs/graphs.md#build-and-run-a-graph).

**Choose the events you stream, and name the run.** `stream_events/3` honors
`stream_mode:`, and `invoke/3` and `stream_events/3` take `run_id:`. See
[Streaming](docs/streaming.md#events).

**Private keys saved with the thread.** `Graph.private_channel/2` takes
`checkpoint: true`, so the next run on the thread starts from the key's value.
See [Private keys](docs/graph_state.md#private-keys).

#### Models and providers

**New models.** Gemini 4 Argon (`google:gemini-4-argon`), Grok 4.7
(`xai:grok-4.7`), Z.ai's `zai:glm-5.3-flashx`, `zai:glm-5.1`, `zai:glm-5`,
`zai:glm-4.7` and `zai:glm-4.6`, and TypeSafe Jev 1.14 (preview alias). See
[xAI models](docs/providers/xai.md#models) and [Z.ai
models](docs/providers/zai.md#models).

**Provider features.** Gemini 4 Argon combines long-decode hops into one
reply. DeepSeek has `Client.search/3` and `Client.fetch/3`. GLM-5.3-Flash
takes images, video and PDFs. OpenAI Responses messages take
`configuration_update` and `additional_tools` blocks. Kimi K3, xAI, Gemini,
Chat Completions and OpenAI Images take more provider options. See
[Google](docs/providers/google.md#gemini-4-argon) and the [provider
guides](docs/providers.md).

**One set of error types for every provider.** A failed model call's error
type follows the HTTP status, not the provider, and `retry_on: :error` skips
errors that say retrying can't help. A stream error with an undocumented code
is a retryable server error and is logged. See [Errors](docs/models.md#errors).

**Model lifecycle and cost estimates.** Deprecated models remain usable until
retirement, and cost estimates account for cache writes and long-context
pricing. See [token usage](docs/models.md#token-usage).

**Decision models.** OpenAI's Decisions API is a decision model, and
`DecisionModel.choice_question/3`, `yes_no_question/2`, `choose/4` and
`probability/4` work with any decision model. See [Decision
models](docs/models.md#decision-models).

**Reasoning effort and the same options on every provider.**
`Models.Profile` has `reasoning_effort_levels` and `reasoning_effort_default`,
and Anthropic models take `reasoning_effort:`. Every chat provider takes
`stream: true`, `max_tokens:` and `max_output_tokens:`, and an agent offers a
provider's built-in tools from its model options. See
[Reasoning](docs/models.md#reasoning) and [Common
options](docs/models.md#common-options).

#### Memory, storage and retrieval

**Postgres schemas, large vector stores and memory pruning.** `prefix:` on
the Ecto adapters uses tables in a Postgres schema, `index: false` on the
`:vector_store` migration allows more than 2,000 dimensions, and
`BeamWeaver.Memory.prune/2` works on `Memory.Ecto`. See [Create the
tables](docs/storage.md#create-the-tables) and [Expiry and
cleanup](docs/long_term_memory.md#expiry-and-cleanup).

#### Tracing and telemetry

**Trace store, trace metadata and telemetry.** `max_runs:` bounds the local
trace store, and `BeamWeaver.Tracing.clear/0` empties it, replacing the
undocumented `Tracing.reset/0`. `ChatModel.invoke/3` takes `trace_metadata:`,
which is never sent to the provider, the WeaveScope queue keeps uploading on
shutdown, and graph telemetry events carry `duration`. See [Read a
trace](docs/tracing.md#read-a-trace).

#### Tools, filesystem and sandboxes

**Exit codes and tool error text.** `execute` results carry the exit code in
`metadata.exit_code`, and tool error messages carry the tool's own error text
in `metadata.error_message`. See [Sandboxes](docs/sandboxes.md#exit-codes).

**Where a path leads, and a check for your backend.**
`BeamWeaver.Filesystem.canonical_paths/3` follows a backend's symlinks, and
`BeamWeaver.Filesystem.Conformance.check_symlinks/3` checks that permission
rules see through them. See [Check that permissions see your
links](docs/filesystem.md#check-that-permissions-see-your-links).

#### Compaction engine

**Anti-thrash state.** `BeamWeaver.Compaction.Result` has `anti_thrash`, the
lane state to save. See [Results](docs/compaction_engine.md#results).

#### Testing

**Whole agent runs without an API key.** `FakeChatModel.tool_call/2`,
`tool_calls/1` and `final/1` script a whole tool loop on `"fake:chat"`, and a
`responses:` list plays one entry per model call instead of always the first.
See [Script the model](docs/testing.md#script-the-model).

### Breaking changes

#### Security

- Host commands start from a minimal environment: `Sandbox.Local`,
  `Filesystem.LocalShell`, `Tools.Shell` and the `ShellTool` middleware no
  longer pass your application's environment, API keys included, to commands,
  only `PATH`, `HOME`, `LANG` and a few more. Put what commands need in
  `env:`, or pass `inherit_env: true`. `ShellPolicy`'s `env_allowlist:` is
  gone, and `ShellPolicy.new/1` returns an error for an unknown option.
- `ShellPolicy` checks every command a line would run, looking through
  wrappers such as `env` and `sh -c`, so chaining, quoting or a wrapper can't
  get around a rule: allow the specific commands, not the wrapper. Regex allow
  rules allow a single command; set `allow_compound: true` for chained lines
  such as `cd x && make`. `ShellPolicy.check/2` says why a command is refused.
- `ShellPolicy` refuses a command that runs code it can't read from the
  command line (`python -c`, `bash script.sh`, `$TOOL args`, setting
  `LD_PRELOAD`), even when a rule for the program matches. Add a rule that
  spells that part out (`"python3 -c"`), or set the new `allow_opaque: true`.
- `Agent.Middleware.ShellTool.new/1` requires a `:policy`; it used to allow
  every command. A shell `Session` refuses a custom `:executor` instead of
  running commands on the host: use the one-shot `BeamWeaver.Tools.Shell`,
  which checks the policy before its executor runs, or a `BeamWeaver.Sandbox`.
- `TextSplitter.split_url/3` fetches only `https` URLs to public addresses by
  default, also after DNS lookups and redirects, and returns an `:unsafe_url`
  error for others. To fetch an `http` or internal URL, pass a `url_policy:`
  that allows it (`schemes:`, `allowed_hosts:`, `allow_private?: true`).
- An `interrupt_on` rule map always turns on human review for its tool, with
  all four decisions allowed by default; a map without `allowed_decisions`
  used to let the tool run unreviewed. Map a tool to `false` to skip review. A
  rule that can't be read is an `:invalid_agent` error.
- `Filesystem.Permission` rules match a path as the backends read it, so
  `/./secrets/key.txt` no longer gets past a `deny` rule for `/secrets/**`;
  deny rules ignore case, and any pattern ending in `/**` covers its folder.
  With rules for an operation, pass absolute paths: a relative path, or one
  with `..`, `~` or `\`, is denied.
- `Filesystem.Permission` rules see through symlinks: a path must be allowed
  both as written and as the file it leads to. A backend or sandbox adapter
  that wraps another must pass on the new optional callback
  `canonical_paths/3`, or the rules won't see the inner backend's links.
- `glob` and `grep` on `Filesystem.Local` and `Filesystem.LocalShell` search
  only inside their directory: a pattern with `..` or `~` returns
  `"invalid_pattern"` (pass the folder as `path:` instead). These backends and
  `Sandbox.local/1` leave out or refuse symlinks that point outside.
- `Sandbox.Local` reads a full host path inside its root
  (`<root>/secrets/key.txt`) as a sandbox path, so it can't slip past a deny
  rule. Pass sandbox-absolute paths (`/secrets/key.txt`).
- `PII` checks the text blocks of multimodal messages and every message a
  model call adds, before they are saved. It has no `after_model/3` hook:
  output rules run in its `wrap_model_call/3`, so call that to test one.
- `ModelFallback` and `TypeSafeModelRouter` call a fallback or chosen model
  with its own key and connection settings, not the agent model's `api_key:`,
  `base_url:`, `endpoint:` or `transport:`. Give such a model its own key, for
  example `init_chat_model!("anthropic:claude-haiku-4-5", api_key: ...)`.
- The `[:beam_weaver, :models, :param_warning]` and
  `[:beam_weaver, :provider, :unsupported_feature]` telemetry events no longer
  carry the call's `metadata:`, which can hold a user id, and
  `BeamWeaver.Models.ParamPolicy.validate/4` no longer takes `:metadata`.

#### Agents

- `BeamWeaver.Agent.build/1` returns an `:invalid_agent` error for an option it
  doesn't know, such as `response_schema:` (use `response_format:`) or the
  removed aliases `backend:`, `permissions:` and `overflow_clip:` (use
  `filesystem:`, `filesystem_permissions:`, `overflow_recovery:`). An invalid
  tool, middleware or capability setting is an error, also from agent modules,
  instead of an exception: match on the error instead of rescuing.
- `build/1` and agent modules reject a `tools` entry that isn't a tool
  (`:invalid_tool`) and a `response_format` or `response_schema` that isn't a
  schema. Declare one with `use BeamWeaver.Schema` or `json_schema/0`.
- A `model` that is neither a `"provider:model"` string nor a chat model
  struct, such as `{"fake:chat", opts}` or a function, returns an
  `:invalid_agent_model` error, and model options that aren't a keyword list
  an `:invalid_agent` error.
- With the tool strategy, an answer that calls no tool is retried up to
  `max_retries` times, then fails with `:missing_structured_output`, instead
  of ending without `structured_response` or looping to `:recursion_limit`.
- An agent or graph module that creates an in-memory saver, store or cache in
  a declaration, such as `checkpointer BeamWeaver.Checkpoint.ETS.new()`,
  doesn't compile, as every call got a new, empty table. Create it once and
  pass it with `checkpointer:`, `store:` or `cache:`, or use
  `Checkpoint.Ecto`, `Memory.Ecto` or `Cache.Ecto`.
- A run ends on its tools' results only when every call of the batch ran a
  tool with `return_direct true`.
- `BeamWeaver.Agent.get_state/2` no longer takes a bare config map; pass
  `config: config`.
- Removed all 164 `async_*` twins, such as `ChatModel.async_invoke/3`, and
  `BeamWeaver.Core.Async`: use `Task`, or `BeamWeaver.Tracing.async/2` to keep
  the trace context. `MessagesTransformer.process_many/3` went with them; call
  `MessagesTransformer.process_many(transformer, events)`.
- Removed `BeamWeaver.Runtime.Agent`, `BeamWeaver.DispatchHook`,
  `BeamWeaver.ProcessRegistry`, `BeamWeaver.Agent.Server` and the generated
  `start_link/1`/`child_spec/1` on agent modules. Call `MyAgent.invoke/2`,
  under your own `Task.Supervisor` for background runs.
- Removed `Core.AgentSchema` and `Core.ChatSession`.
- Removed the `debug` declaration and `build/1` option; watch a run with
  streaming or tracing.
- Removed the `tool_timeout` model option; declare `tool_timeout` instead.

#### Middleware

- `BeamWeaver.OpenAI.ModerationMiddleware` is now
  `BeamWeaver.Agent.Middleware.OpenAIModeration`, and
  `OpenAI.moderation_middleware/1` is gone: list
  `{BeamWeaver.Agent.Middleware.OpenAIModeration, opts}` in `middleware`.
- `CompactConversation` no longer adds a section about its tool to the system
  prompt by default; `system_prompt:` still adds one of your own.
- The automatic summarization that the `compact_conversation` declaration
  turns on summarizes all the old messages, not only the newest 4,000 tokens;
  set `summarization: [trim_tokens_to_summarize: n]` to limit it.
- The `compact_conversation` settings configure only the tool, and other
  options raise `ArgumentError`: move `trigger:` and `keep:` into
  `summarization: [trigger: …, keep: …]`.
- The summary the `compact_conversation` tool writes ends with a line naming
  the file the replaced messages were saved to; match the start of the
  summary text instead of all of it.
- A middleware hook's update is written as returned, even when a value equals
  the current one. Return only the keys you change: returning the whole state
  fails with `:invalid_update`.
- `Agent.ModelRequest.new/1`, `ModelRequest.override/2` and
  `ToolCallRequest.override/2` take keyword lists and raise `KeyError` for
  unknown fields; string field names are no longer accepted.
- `ModelCallLimit` and `ToolCallLimit` have no default `thread_limit` (it was
  10): set `run_limit`, `thread_limit`, or both.
- `Summarization` takes `{:fraction, f}` of `max_input_tokens:` instead of the
  summary model's context window; pass the agent model's window.
- `OverflowRecovery`'s `keep:` defaults to `{:tokens, 5_000}` and no longer
  takes `{:messages, n}`; use `{:tokens, n}` or `{:fraction, f}`.
- `PII.stream_transform/1` returns a `{fun, state}` pair, which
  `MessagesTransformer`'s `pre_projection:` accepts.
- `PII` output rules no longer edit the arguments of the reply's tool calls;
  check them in the tool or in a `wrap_tool_call/3` middleware.
- `ModelRetry` and `ToolRetry` apply `on_failure` only when the retries run
  out; an error their `retry_on` doesn't cover comes back as it is instead of
  becoming the answer.
- `retry_on: :error`, the default of `ToolRetry` and of a graph node's
  `retry:`, leaves out errors marked `details.retryable: false`, such as an
  invalid API key. Name the type (`retry_on: [:authentication]`) or use
  `retry_on: :all` to retry them anyway.
- `TypeSafeModelRouter` takes any decision model as `classifier:`, also as a
  `"provider:model"` string. Match the reasons `"refused"` and
  `"classifier_error"` instead of `"invalid_classifier_response"`. Its default
  `instructions` are one string, and the struct keeps the built question in
  `question`.
- `@behaviour BeamWeaver.Agent.Middleware` on its own no longer makes a
  middleware: call `use BeamWeaver.Agent.Middleware`. Agents reject modules
  that don't (`:invalid_middleware`).
- Removed two-argument middleware hooks. Every hook takes the middleware
  first: `before_model(middleware, state, runtime)`,
  `wrap_model_call(middleware, request, handler)`, and so on.
- Removed the `can_jump_to/2` and `tool_node_required?/1` middleware
  callbacks and functions; delete them from your middleware. A hook jumps by
  returning `{:jump, target, update}`.
- Removed string kinds in `Summarization` `trigger:`/`keep:`
  (`{"messages", 10}`); use atoms.
- Removed the `Agent.Middleware.Exclusion` helpers.

#### Subagents and deep agents

- `Agent.Middleware.Subagents` and `AsyncSubagents` add nothing to the system
  prompt by default, and the `task` tool's description is a short set of usage
  notes. Pass `system_prompt:` for a section of your own; `task_description:`
  still replaces the description.
- The general-purpose subagent, and any subagent with
  `base_middleware: [:deepagents]`, no longer gets `write_todos`. Add
  `Agent.Middleware.TodoList` to its `base_middleware:` or `middleware`.
- An async subagent without a `client:` or a `url:` fails the build with
  `:invalid_agent` (`AsyncSubagents.new/1` raises `ArgumentError`). An
  `%AsyncSpec{}` struct with a `url:` now gets `Agent.Protocol.ReqClient`.
- `subagent MyApp.Module` runs the module with all of its declarations
  (`model` options, `filesystem`, `skills`, `memory`, `subagents`, timeouts,
  `checkpointer` and the rest). Pass `skills: nil` (or another option) on the
  `subagent` line to leave one out.
- Subagents use the run's checkpointer and store, saving in the parent's
  thread; `Agent.Middleware.Subagents.new/1` no longer takes `checkpointer:`.
  A parent whose subagents review tool calls fails with
  `:missing_checkpointer` before it starts: pass `checkpointer:` and a thread
  id, or set `interrupt_on: false` on that subagent.
- `Agent.Subagent.Spec.new/1` and `subagent` lines raise `ArgumentError` for
  unknown options, and the `todo_list` field is gone.
  `Spec.from_agent_module/2` raises for a graph module; run it as a
  `%BeamWeaver.Agent.Subagent.Compiled{}`.
- The async subagent tools return only the tasks they change
  (`%Command{update: %{async_tasks: %{task_id => task}}}`), so parallel calls
  no longer undo each other. Read the whole map from the agent's state.
- `BeamWeaver.Agent.build/1`, and an agent module on its first call, check
  every subagent and return `{:error, %Core.Error{type: :invalid_subagent}}`
  naming it, instead of failing each `task` call. `graph/0` raises it.
- Removed the standalone `BeamWeaver.Todo` model.

#### Human review, checkpoints and resuming

- A new message to a thread paused on a tool-call review answers the waiting
  calls as not run instead of pausing again, and a later `resume_review/3` for
  that review changes nothing. Resume a review before sending a new message
  when its decision should count.
- An `:edit` decision leaves the model's call in its message and runs the
  reviewer's call, whose result starts with a note (`HumanInTheLoop`'s
  `edit_notice:` words it, `nil` leaves it out). Read the call that ran from
  the decision or the result.
- A `:reject` decision's tool result says the user rejected the call, instead
  of the `message` alone.
- `get_state/2` `interrupts` and `interrupt.interrupts` list each interrupt of
  a paused subgraph instead of one nested record. Answer them by id
  (`Map.new(interrupt.interrupts, &{&1.id, answer})`).
- `bulk_update_state/4` without `as_node:` after a step that ran several
  routing nodes fails with `:ambiguous_state_update`; pass `as_node:`.
- Removed strict-resume checkpoints (`Checkpoint.stage_resume/3`,
  `continue_staged/2`, `verify_resume_receipt/2`,
  `Checkpoint.ResumeDelivery`) and `Checkpoint.Utils`.

#### Graphs

- Graph modules `use BeamWeaver.Graph` instead of `use BeamWeaver.Agent`;
  change the `use` line of any module that defines `graph/0` or declares
  `node`, `edge`, `reducer` or `graph do ... end`. They have no
  `resume_review/2` (call `resume/2`) or agent-only declarations (pass
  `input_schema:` and `output_schema:` to `Graph.new/1`), and string keys no
  longer move into `raw_input`.
- An agent module must declare a `model` and can't define `graph/0` or graph
  declarations; the compile error points to `use BeamWeaver.Graph`.
- `graph/0`, `checkpointer/0` and `store/0` are callbacks of the
  `BeamWeaver.Graph` behaviour; mark them `@impl true` or
  `@impl BeamWeaver.Graph`.
- `BeamWeaver.Agent.compiled_graph/2` takes agent modules only; call a graph
  module's own `compiled_graph/1`. Module nodes have the kind `:subgraph` in
  `Compiled.get_graph/2` and `draw_mermaid/2`, not `:agent`.
- `BeamWeaver.Graph.Nodes.ToolNode` and `ValidationNode` are now
  `BeamWeaver.Agent.ToolNode` and `BeamWeaver.Agent.ValidationNode`; their
  functions and options are unchanged.
- A step in which one task fails and another pauses returns the error; the
  pause stays pending. Resume the thread once you have dealt with the error.
- `ToolNode` answers a `tool_call_with_context` input with
  `%{messages: [...]}` instead of a list; read the messages key.
- Graph nodes, `ToolNode` tools, `Compiled.batch_as_completed/3` and
  `BeamWeaver.ExecutionPolicy` no longer time out after 5 seconds by default.
  Pass `timeout: 5_000` to keep the old limit (in an agent, declare
  `tool_timeout`).
- `Graph.add_node/4` rejects unknown options, and a node with invalid options
  fails `Graph.compile/2` with `:invalid_graph` instead of failing when it
  runs. The message is now "graph contains invalid nodes".
- A node or error handler that returns `{:error, reason}` fails the node, so
  `retry:` and `error_handler:` apply and the run returns a `:node_error`,
  instead of storing the tuple in the state under `:value`.
- `EphemeralValue` keys, and `Topic` keys without `accumulate: true`, last
  one step instead of the rest of the run. A channel that holds a value but
  got no write in a step now receives `update(channel, [])`.
- The message reducers in `Graph.Messages` accept what
  `BeamWeaver.Core.Message.from/1` accepts, so they reject the roles `"human"`
  and `"ai"`; use `"user"` and `"assistant"`.
- `max_runs:` on a guarded edge counts within one run (a `resume/3` keeps the
  count), not across a thread. For a thread-wide limit, count the rounds in
  the state and check them in the edge's `when:` function.
- An `Overwrite` written to a `DeltaChannel` key drops the other writes of its
  step, as on a reducer key, live and after a reload.
- Removed the `failure_policy:` graph option, which was never implemented.
- Removed the node option aliases `retries:` and `on_error:`; use `retry:` and
  `error_handler:`.
- Removed `Graph.Errors`, `Graph.MessagesReducer`, and `Graph.Schema` (use
  `BeamWeaver.Schema`).
- Removed `DeltaChannel.replay_history/4`, which returned wrong values; use
  `get_state/2`.

#### Streaming

- `stream_events/3` without `live: true` collects the same stream a live call
  returns, from `Debug` `:producer_start` to `:producer_stop`. `Done` now only
  ends a streamed model call; use the `{:ok, _}`/`{:interrupted, _}`/
  `{:error, _}` result for how the run ended. The `namespace:` option is gone.
- In an agent's stream, a failed model call sends a `Debug`
  `%{type: :model_call_failed}` event instead of the provider's `Error` event,
  so `Error` only ends a failed run; drop the failed call's tokens when the
  `Debug` event arrives.
- `BeamWeaver.Graph.Runtime` no longer has a `collect_stream?` field; check
  `stream_sink`.

#### Memory, storage and caching

- `Memory.ETS` and `Memory.Ecto` take the same TTL options, `default_ttl:`
  (minutes) and `refresh_ttl:` (default `false`); they replace `Memory.ETS`'s
  `ttl:` map and `ttl_config:` and `Memory.Ecto`'s `refresh_on_read?:`.
  `Memory.ETS` no longer refreshes by default, a refresh restarts the record's
  own lifetime, and both `new/1` functions raise `ArgumentError` for unknown
  options.
- `Memory.Ecto` needs memory schema version 2: add a migration that calls
  `BeamWeaver.Migrations.up(adapters: [:memory])` (`verify_migrated!/1` raises
  until you do). For a store that used `refresh_on_read?: true`, pass its
  `default_ttl:`, as in
  `BeamWeaver.Migrations.up(adapters: [{:memory, default_ttl: 60 * 24}])`, so
  no stored record gets a longer lifetime.
- `Serialization.Config` keeps codec options such as `:encryption_key` in
  `opts`, and `Serialization.dump/2` and `load/2` pass the codec only those;
  put codec options in `serialization: [...]`. `Serialization.Encrypted` no
  longer reads a nested `serialization:` list.
- `BeamWeaver.Serialization` keeps map keys' types at any depth, so
  `Checkpoint.Ecto` and `Cache.Ecto` give back `%{order: %{id: "A-1001"}}`
  instead of `%{"order" => %{"id" => "A-1001"}}`. Loading creates no atoms and
  builds no struct the registry doesn't list. Data saved earlier loads as
  before; code that read string keys from loaded values reads the saved keys
  (`["channel_values"][:order][:id]`).
- `BeamWeaver.Memory.batch/2` checks every namespace and key as `put/5` does
  and returns `{:error, {:invalid_namespace, message}}` without running any
  operation; a failed put or delete returns `{:error, error}`. `search/3` and
  `list_namespaces/2` return that error for an invalid prefix instead of `[]`.
- `Checkpoint.prune/3` returns an `:invalid_prune_strategy` error for an
  unknown `strategy:` instead of running `:keep_latest`.
- `Checkpoint.delete_for_runs/2` returns a `:delta_history_in_use` error and
  deletes nothing when a later checkpoint still reads `DeltaChannel` history
  from those runs.

#### Tracing and telemetry

- An agent's structured-output trace run is named `"StructuredOutput"`, not
  `"RunnableSequence"`.
- Removed the supervisor-first `Tracing.async(supervisor, fun)` form; use
  `Tracing.async(fun, supervisor: supervisor)`.

#### Retrieval, prompts and parsers

- `Retriever.as_tool/2` takes `document_prompt:` as a template string, such as
  `"{source}: {content}"`, instead of a prompt; pass `document_formatter:` for
  other formatting.
- Chunks no longer copy their document's `id`: they get ids made from it
  (`"refunds:0"`, `"refunds:1"`, ...) and carry it as `"parent_id"` in their
  metadata.
- Removed the prompt kit (`BeamWeaver.Prompt`, `BeamWeaver.Template`,
  `BeamWeaver.ExampleSelector`); chat models no longer take a `Prompt.Value`.
  Write prompts with string interpolation or EEx.
- Removed `BeamWeaver.OutputParser`; use `JSON.decode/1` or
  `response_format:`.
- Removed `BeamWeaver.Runnable` and `Retriever.as_runnable/1`; graph nodes no
  longer take Runnables. Use node functions, `Core.DecisionModel.invoke/3`,
  `Retriever.retrieve/3`, and compose with functions and `with`.
- Removed `BeamWeaver.Indexing` and its record managers; use
  `VectorStore.add_documents/3` and `VectorStore.delete/2`.
- Removed `Core.ChatHistory` (keep a conversation in a thread with a
  checkpointer), `Core.LLM`, `Models.FakeLLM`, the text `complete/3` and
  `stream/3` of `Models.cached/3`, and `Tool.Converter`.
- Removed document loaders and blobs (`DocumentLoader`, `DocumentTransformer`,
  `DocumentIndex`, `Blob`, `BlobLoader`, `BlobParser`, `BlobLike`,
  `DocumentLike`), `Indexing.DocumentIndex`, `StructuredQuery`,
  `DocumentCompressor`, `CrossEncoder`, `Core.HTML`, and `Core.Strings`. Load
  sources into `%Core.Document{}` with plain Elixir or `Core.Document.from/1`.
- Removed `Core.Document.lc_namespace/0`, `serializable?/0`,
  `langchain_string/1`, the `type` field, and its `String.Chars` impl.
- Removed the text splitter option aliases `is_separator_regex`,
  `max_chunk_size`, `headers_to_split_on`, and `strip_headers`.

#### Tools

- `Core.Tool.invoke/3` returns a `%Core.ToolResult{}` with `content` and
  `artifact` for a `response_format :content_and_artifact` tool, instead of
  the content alone; read `result.content`.
- When several tool calls of one step return a `%BeamWeaver.Graph.Command{}`,
  every update goes through the key's reducer, so two tools that write a key
  without one fail with `:invalid_update`. Declare a reducer for such keys.
- A tool that injects `:state` no longer sees the agent's private keys (such
  as `usage` and `tool_set`) or managed keys (such as `remaining_steps`); name
  a key it needs with `injected :name, {:state, :key}`.
- `@behaviour BeamWeaver.Core.Tool` on its own no longer makes a tool; write
  `use BeamWeaver.Core.Tool`.
- Removed `Core.Tool.run/3` (use `invoke/3`) and `Tools.Helpers`.

#### Filesystem and sandboxes

- `glob` and grep's `glob:` read a pattern the same way on every backend: one
  without `/` matches a file's name at any depth (`*.py` finds
  `/src/app/main.py`), one with `/` matches the path from the path searched,
  and a leading `/` anchors it. Write `/*.py` for top-level files only, which
  `*.py` used to mean on most backends. Character classes, `{md,txt}` and `\`
  work everywhere, and an unclosed `[` or `{` is `invalid_pattern`. See
  [Glob patterns](docs/filesystem.md#glob-patterns).
- `ls`, `glob` and `grep` of a path that doesn't exist return the error
  `file_not_found` on every backend instead of an empty list, and `grep` with
  a file as its `path` searches that file.
- `write/4`, and so the `write_file` tool, replaces a file that exists on every
  backend instead of returning `file already exists`. Writing over a directory
  is still an error.
- When `execute` output is over its limit, `LocalShell` and the local and
  Docker sandboxes keep its first and last halves, with a line such as
  `... [48210 bytes cut] ...` between them, instead of only the first bytes;
  `truncated` is still set.
- `read_file` returns at most 80,000 characters, cut at a whole line, and a
  page that stops short of the end of the file ends with a note giving the
  offset to read on from.
- `read_file` returns an image (PNG, JPEG, GIF, WebP) or a PDF as a content
  block with its media type, and any other binary file as a short notice with
  its size, instead of an `"image"` block for every binary file.
- `ls`, `glob` and `grep` results stop at 80,000 characters, after the last
  whole entry, with a note asking the model to narrow the search.
- `read_file` rejects a negative `offset` and a `limit` below 1, and an
  `offset` past the last line returns an error instead of `""`.
- `edit` with an empty `old_string` returns the error
  `"old_string must not be empty"` on every backend.
- Reading an empty file on `Filesystem.State` or `Filesystem.Store` returns
  `System reminder: File exists but has empty contents`, as the other backends
  do, instead of `""`.
- `Filesystem.State.write/4` and `edit/5` return only the changed file in
  `files_update`, as `%{path => file_data}`, not the whole files map. Merge it
  into the state's files.
- `Sandbox.Docker` operations on a sandbox that isn't started return
  `error: "container_not_started"` instead of starting a container that is
  never removed. Call `Docker.start!/1` and use the sandbox it returns. With
  `remove: true` (the default) the container is removed when the process that
  started it exits; pass `remove: false` to keep it until `Docker.stop/1`.
- `Filesystem.State.upload_files/3` returns an error for every file instead of
  reporting success while storing nothing. Pass State files in the agent's
  input as `files:`, or set them with `Graph.Compiled.update_state/4`.
- Removed the forwarding protocols `Graph.Channel.Dispatch`,
  `Filesystem.Backend`, `Filesystem.ExecutableBackend` and `Sandbox.Backend`.
  `use BeamWeaver.Graph.Channel` (and `Filesystem`, `Filesystem.Executable`,
  `Sandbox`) declares the behaviour; check an implementation with
  `Channel.implemented_by?/1`, `Filesystem.backend?/1`,
  `Filesystem.Executable.executable?/1` or `Sandbox.sandbox?/1`.
- Removed `Filesystem.Utils`, `Filesystem.is_directory/0` (use
  `directory_error/0`), and `Filesystem.ls_info/3` and `glob_info/3` (use
  `ls/3` and `glob/3`).

#### Models and providers

- `Core.DecisionModel.batch/3` fails a batch whose call exits or outlasts
  `timeout:` with `:decision_batch_exit`, not `:runnable_batch_exit`. Decision
  model calls no longer take `config:`, `configurable:`, `context:`,
  `recursion_limit:` or `opts:`.
- A failed model call's error type follows the HTTP status on every provider:
  `:invalid_request` (400, 422), `:authentication` (401, and Gemini's and
  xAI's 400 for a wrong key), `:billing_exhausted` (402), `:permission_denied`
  (403), `:not_found` (404), `:rate_limit` (429) and `:server_error` (every
  5xx, all retryable). No response is `:connection` and a timeout `:timeout`.
  Match these instead of `:http_error`, `:transport_error` and DeepSeek's,
  Kimi's and Z.ai's `:*_error` types (`:billing_exhausted` for
  `:quota_error`); other statuses are still `:http_error`.
  `Transport.ReqFinch` reports a timeout as a `:timeout` `Transport.Error`,
  not `:transport_failure`.
- A profile's reasoning efforts are fields: read `reasoning_effort_levels`
  instead of `extra.reasoning_efforts` or `extra.effort_levels`, and
  `reasoning_effort_default` instead of `extra.default_reasoning_effort` or
  `extra.default_effort`.
- `init_chat_model/2`, `init_embeddings/2` and `init_decision_model/2` return
  `{:error, %Error{type: :unsupported_model_param}}` for an option the model
  doesn't take, such as a misspelled one, and OpenAI and xAI Responses and
  Anthropic calls do the same for a parameter the model's profile doesn't
  list, such as `top_k:` or `stop:` (as does `stop:` on xAI reasoning models
  over Chat Completions); they used to drop it. Errors from the `init_*`
  functions carry `details.provider`. Pass call options such as `tools:` or
  `tool_choice:` with each call or through `Models.bind_tools/3`.
- The `api:` option of OpenAI and xAI returns `:invalid_provider_option` for a
  value other than `:responses` or `:chat_completions` instead of falling back
  to Responses.
- A missing API key fails before any request with `:missing_api_key`
  (`details.provider`, not retryable) on every provider instead of sending the
  request without credentials; TypeSafe's `:model_authentication` is now
  `:missing_api_key`. A key in an `authorization` (or the provider's key)
  header in `default_headers:` counts.
- A `:transport_error` keeps the transport's error type in `details.reason`
  (such as `:cassette_mismatch` or `:timeout`) and its details, instead of an
  inspected string, and a `BeamWeaver.Core.Error` from a transport is returned
  unchanged.
- `Core.Messages.Utils` renames `messages_to_dict/1` to `encode/1`,
  `messages_from_dict/1` to `decode/1`, `get_buffer_string/2` to
  `buffer_string/2` and `convert_to_openai_messages/2` to
  `to_openai_messages/2`, which with `api: :responses` returns one flat list
  of items. `message_to_dict/1` and `convert_to_messages/1` are removed; use
  `encode/1` and `normalize/1`.
- The `:approximate` token counter and
  `LanguageModel.count_tokens_approximately/1` estimate about four characters
  per token plus three per message instead of counting words. This changes
  `Messages.Utils.trim/2` (including `allow_partial: true`), the
  `:approximate` `ContextEditing` counter and `count_tokens` of models without
  a tokenizer; raise budgets that were set in words.
- `Models.UsageCost` reads pricing maps with atom keys only; raw provider usage
  maps may still use string keys.
- `Transport.Safe` ignores a `:finch` option, since every request runs on the
  isolated pools (see Security). Pass connection settings, such as a proxy or
  `transport_opts` with CA certificates, as `connect_options:`.
- xAI Responses requests to a reasoning model carry
  `"include": ["reasoning.encrypted_content"]`, added to an `include:` list
  you pass (`extra_body: %{include: [...]}` replaces it). Re-record cassettes
  and fakes that match xAI request bodies exactly, or add the field.
- `use_previous_response_id: true` on OpenAI continues only from a reply with
  `response_metadata.model_provider == "openai"`, so another provider's `resp_`
  id (such as DeepSeek's after a fallback) is no longer sent. Add
  `model_provider: "openai"` to a reply built by hand, or pass
  `previous_response_id:`.
- `OpenAI.ModerationMiddleware` and `moderate/2` return the client's error when
  the moderation request fails, such as `:missing_api_key`, `:http_error` or
  `:transport_error`, instead of `:openai_moderation_request_failed`. Match on
  those types.
- Typed streams are made of `BeamWeaver.Stream.Envelope` structs to the end: a
  failed provider stream no longer ends with a bare `%Events.Error{}`, and a
  wrapped model (`Models.bind_tools/3`, `with_rate_limiter/2`, `cached/3`)
  ends with an `Error` envelope instead of a `Custom` event and `Done`. Match
  `%Envelope{event: %Events.Error{}}`.
- A model stream that reports an error partway through, including a Responses
  stream that ends with `response.failed`, fails with the error the same
  failure gets without streaming (such as a retryable `:server_error` with
  `status: 503`) instead of `:response_error` or `:response_failed`. Match on
  the error type and `details.status` or `details.code`. Text and raw
  lifecycle streams end with an `Error` event after such an error.
- A Z.ai or DeepSeek reply whose finish reason says the provider couldn't
  finish it fails the call, with or without streaming, instead of being
  returned as complete: Z.ai's `sensitive` is a `:content_filter` error that
  isn't retried, and Z.ai's `network_error` and DeepSeek's
  `insufficient_system_resource` and `aborted` are retryable server errors,
  with the finish reason in `details.code`. Handle the error instead of the
  reply's `status`.
- Chat models check `metadata:` and return `:unsupported_model_param` naming
  the key for what the provider's API doesn't take: Anthropic takes only
  `user_id` (a string of at most 512 characters), OpenAI at most 16 pairs with
  keys of at most 64 characters and string values of at most 512, and
  Moonshot, DeepSeek, Z.ai and xAI none. Anthropic, OpenAI and xAI check a
  model's own `metadata:` in `init_chat_model/2`, so an agent with it fails
  before its first model call. Put trace data in `trace_metadata:`; for an
  end-user id, DeepSeek and Z.ai take `user_id:` and Moonshot
  `safety_identifier:`.
- Provider client functions no longer take a keyword list in place of a client;
  build one with `Client.new/1`, which takes keyword lists only. Per-call
  options still override `:endpoint`, `:api_key`, `:transport`,
  `:transport_opts`, `:timeout` and `:headers`, but no longer other client
  fields such as `:default_headers` or `:base_url`.
- Removed `Models.with_structured_output/3`. For one call, pass
  `response_format: %{name: ..., schema: ...}` to `ChatModel.invoke/3` and
  read `metadata.parsed` (was `metadata.structured_response`); for a strategy
  per model with tool-call fallback and retries, give an agent a
  `response_format`.
- Removed `ChatModel.generate/3`, `generate_prompt/3`, `LLM.generate/3` and
  `LLM.generate_prompt/3`; use `batch/3`.
- Removed `Provider.ReasoningControl`; pass `reasoning_effort:` to the model.
- Removed `OpenAI.Client.endpoint/1`, which took a path only; call
  `OpenAI.Client.endpoint(client, path)` with a client or a base URL.
- Removed `Core.Error.create_message/2`, `error_codes/0`, `output_parser/2`,
  `context_overflow/2` and `tracer/2`, and the decoding of `lc`/`kwargs`
  message envelopes.
- Removed the `Core.MessageLike`, `Core.ContentBlockLike`, `Tool.SchemaLike`
  and `ExampleLike` protocols. Use `Core.Message.from/1`,
  `Core.ContentBlock.from/1` and `Tool.Schema.from/1`.
- Removed the typed message structs (`Core.Messages.System`, `User`,
  `Assistant`, `Tool`, `Function`, `Chat`, `ToolChunk`, `FunctionChunk`) and
  the `Core.Messages.system/2`-style constructors and `to_message/1`. Use
  `Core.Message.system/2` and friends.
- Removed the role aliases: messages, `Utils.filter/2` and `trim/2` accept only
  `"user"`, `"assistant"`, `"system"`, `"tool"` and `"developer"` (or the
  atoms), and no longer read `"human"`, `"ai"`, `"function"`, `type` for
  `role`, or `additional_kwargs`.
- Removed the `"langchain-openai"` message format name; pass `format: :openai`.
- Removed the `Provider.EncodeMessage` and `Provider.DecodeMessage` protocols;
  use `Provider.MessageCodec.encode/2` and `decode/2`. With
  `provider: :openai`, `encode/2` returns a list for an assistant message with
  tool calls: its message item and one `function_call` item per call.
- Removed the provider error structs (`OpenAI.Error`, `Anthropic.Error`,
  `Google.Error`, `XAI.Error`, `DeepSeek.Error`, `Moonshot.Error`,
  `ZAI.Error`). Every provider returns `%BeamWeaver.Core.Error{}` with the
  provider in `details.provider`.
- Removed `Provider.ChatRuntime.Adapter`. Provider chat models implement the
  `Provider.ChatModel` callbacks (`request_body/3`, `send_request/4`,
  `decode_response/2`, `parse_response/3`, `stream_metadata/3`).
- Removed `:model_kwargs`. Use `:extra_body`, which every chat model accepts
  as a field and per call (per-call keys win). It is merged after
  BeamWeaver's own fields, so it overrides them (DeepSeek, Moonshot and Z.ai
  keep `model`, `messages` and `stream`, Anthropic its reserved fields).
- Removed `Provider.GenericMessages`, `Provider.HostedTools` and
  `Models.FunctionEmbeddingModel`.

#### Compaction engine

- `Compaction.State.record_success/2` takes the activated
  `%Compaction.Checkpoint{}` and records its trigger, high-water mark, tokens,
  accounting identity and root turn. It replaces
  `record_success(state, trigger, lane_ordinal, tokens_after)`; you no longer
  need `State.rebase_accounting/2` before it.

### Security

- `Transport.URLPolicy`, which `TextSplitter.split_url/3` and `Transport.Safe`
  use, let through addresses it refuses when they were written as
  IPv4-translated (`::ffff:0:a.b.c.d`) or 6to4 (`2002::/16`) IPv6 addresses,
  and also the site-local range `fec0::/10` and IPv6 hosts with a zone id.
  Translated and 6to4 addresses are now judged by the IPv4 address they carry,
  `fec0::/10` is refused, and a host in brackets that isn't a plain IPv6
  address is refused with `:unsafe_url`.
- `Transport.Safe` requests no longer add a connection pool (and, when pinned
  with `pin_resolved?: true`, a Finch instance and new atoms) for every host
  they reach, which could exhaust processes or the atom table when URLs come
  from users or models. They now share at most 16 isolated pools
  (`config :beam_weaver, :transport, max_isolated_pools: 32,
  isolated_pool_idle_timeout: 30_000` changes the limits), and unpinned ones
  stop reading headers past `:max_response_header_bytes`.
- Tools hidden from the model (by `exclude_tools`, a capability profile,
  `ToolSelection` or `ModelRequest.override(tools: ...)`) could be called once
  a run continued after human review, an `interrupt_before: [:tools]`
  breakpoint, a pause inside a tool or a crash. The tools node now runs only
  the tools the model was offered on its latest call, also from a checkpoint.
- `Sandbox.Docker.download_files/3`, which skills load their files with,
  returned the host file a symlink made in the container pointed to, such as
  a `SKILL.md` pointing to `/home/app/.ssh/id_rsa`. It now copies the file the
  symlink leads to inside the container.
- A `PII` output rule (`apply_to_output: true`) also edits the structured
  answer an agent with tools makes after the tool loop, which was saved
  unedited.
- `inspect/1` no longer prints credentials: the API keys and auth headers of
  Anthropic, Google, Moonshot, Z.ai and xAI models and clients,
  `Provider.HTTPClient`, `Transport.Request`, the WeaveScope exporter config
  and async subagent specs, the `env` of
  `Sandbox.Local`, `Filesystem.LocalShell`, `ShellPolicy` and shell `Session`s
  (also in crash logs), and `Serialization.Config` codec options such as
  `:encryption_key`. `:invalid_agent_model`, `:invalid_agent` and middleware
  option errors no longer show them either.

### Changed

#### Agents

- Every declaration in an agent module is evaluated when the agent runs,
  including the options after `model "..."`, `model_opts`, `field` options in
  `context_schema` and `interrupts`, so they can read configuration and call
  functions. `model_opts` is merged over the options after `model`.
- `context_schema` moves a declared field given under a string key to its
  atom key, and a field type that is neither built in nor a struct module is
  an `:invalid_agent` error.
- The "Sorry, need more steps to process this request." answer replaces a
  tool call whenever the steps left can't fit the tool round, the next model
  call and the middleware hooks, so a run with middleware ends with it instead
  of a `:recursion_limit` error.
- Every agent has a tools node, so a call to a tool the agent doesn't have
  gets "Tool error: tool is not registered" back instead of raising
  `KeyError`.
- A declared `checkpointer` or `store` whose function returns a new
  `Checkpoint.ETS` saver or `Memory.ETS` store each time logs a warning on the
  agent's first call.

#### Middleware

- A struct middleware listed as a bare module, `middleware [MyApp.Limit]`, is
  built like `{MyApp.Limit, []}`, so its hooks get the default struct.
- `Middleware.Filesystem`, `Skills`, `Memory`, `CompactConversation` and
  `OverflowRecovery` listed as a module or `{module, opts}` get the declared
  `filesystem` as `backend` (and `Filesystem` the declared
  `filesystem_permissions`) unless their options name others.
- The `ToolSelection` that `exclude_tools` and `tool_descriptions` add runs
  before, and in addition to, a `ToolSelection` listed in `middleware`.
- `DynamicPrompt` runs before the agent's other middleware: it replaces the
  declared `system_prompt`, the sections other middleware add follow it, and
  the structured-response call after a tool loop uses it too.
- `StructuredOutputRetry` puts the failed answer and its error in the retry
  request and the saved thread, so the model sees what it got wrong.
- `ToolRetry` with `on_failure: :error` gives the model the tool's last error
  as is, instead of wrapping it in a second "Tool error: …".

#### Subagents and deep agents

- A subagent with `inherit_messages: true` gets its task after a note that
  the conversation above is the parent's, so it no longer takes the parent's
  request to delegate as its own, and the `task` tool's list marks it as one
  that sees the conversation.
- `interrupt_on: false` (or `%{}`) on a `subagent` line or spec turns review
  off for that subagent instead of taking the parent's rules.
- Subagents may take as many steps as the parent's recursion limit, instead
  of 9,999, unless they set `recursion_limit`, and start without the parent's
  private state, so their call limits count their own run.
- With `capture_output:`, the parent's model reads that the subagent's
  answer was saved under its key instead of `"{}"`.

#### Human review, checkpoints and resuming

- A resume value that no pending interrupt claims goes only to the steps that
  run first; a `Graph.interrupt/1` reached later pauses instead of receiving
  it.
- Edited tool calls are checked against the tool's own input schema as well
  as the rule's `args_schema`. A mismatch fails `resume_review/3` with
  `:invalid_human_decision` instead of running the tool.
- `interrupt.state` is the run's public state, as `get_state/2` shows it,
  without private channels.

#### Graphs

- A `Send`'s `timeout` takes the forms a node's `timeout:` takes. Before, an
  `ExecutionPolicy` or options without `run_timeout` or `idle_timeout` became
  5 seconds; an invalid `timeout` now fails the task with `:invalid_graph`.
- A subgraph node's update holds only the keys the subgraph changed (for a
  reducer key, what it added), and its `input_schema:` and `output_schema:`
  apply, so the parent's reducer no longer applies the subgraph's input twice.
  A resumed subgraph keeps what changed in the parent while it waited.
- `AnyValue` keeps its value through steps that don't write it;
  `update(any_value, [])` no longer clears it.
- A step's update (`GraphUpdate` events and checkpoint metadata) shows a
  reducer key's writes without the channel's starting value, so a message
  removal appears as its `Graph.Messages.remove/1` marker.
- A reducer that raises, a `Send` whose update can't be merged, and a
  `Command` `goto` or `Send` to a node the graph doesn't have fail their task
  with an `:invalid_update` or `:invalid_graph` error instead of raising.
- `use BeamWeaver.Graph.Channel` gives single-value channels (a struct with
  `:key` and `:value`) default `get/1`, `checkpoint/1`, `from_checkpoint/2`
  and `available?/1`.
- `snapshot.pending_writes` of a step that stopped partway lists a
  `"__route__"` entry for each finished task. Code that reads the raw entries
  should skip it, as it skips `"__error__"` and `"__interrupt__"`.

#### Streaming

- Events a node writes (its `runtime.stream_writer`, tool events, a streamed
  model's `Token`, `MessageChunk` and `Done`) carry that node in
  `envelope.node` and, inside a subgraph or subagent, the run's namespace of
  node names without the task id. Step events have `node: nil`.
- `runtime.stream_writer` does nothing during `invoke/3` and `resume/3`.

#### Memory, storage and caching

- `refresh_ttl` on `Memory.GetOp` and `Memory.SearchOp`, which both stores
  ignored, defaults to `nil` (the store's setting), and `true` or `false`
  overrides it for that read. `Memory.search/3` takes `refresh_ttl:` too.
- The `:vector_store` migration raises `ArgumentError` for an `index:` other
  than `:ivfflat`, `:hnsw` or `false`, and for more than 2,000 dimensions with
  an index.
- `Memory.Ecto`, `Cache.Ecto` and `VectorStore.EctoPostgres` quote their
  table names as the migration does, so names with capitals match.

#### Tracing and telemetry

- Middleware trace spans are named after the middleware module, without a
  `Middleware` suffix, such as `TodoList.wrap_model_call`. Update trace
  filters that use the old names.

#### Retrieval, prompts and parsers

- `BeamWeaver.Schema.module_schema/1` returns the schema a module declares
  through `json_schema/0`, `schema/0` or `use BeamWeaver.Schema`.

#### Filesystem and sandboxes

- `grep` adds a note to an empty result when the pattern looks like a regex,
  telling the model that grep matches literal text.
- `grep`'s description and system prompt line say the pattern is literal
  text; while the model is offered `execute`, the description adds that a
  real regex needs `execute` with `rg`.
- A `glob` or `grep` denied without a `path` says it was checked against `/`
  and to retry with a `path` inside an allowed directory. Their `path` no
  longer has a schema default.
- The `execute` tool returns the command's output followed by its exit code,
  such as `[Command failed with exit code 1]`, and after a timeout an error
  saying the command was stopped.
- `Filesystem.Store` without a store returns `"missing_store"` from reads and
  writes, instead of reporting a write as done and dropping it.

#### Models and providers

- Anthropic's `effort:` turns on adaptive thinking with its summary on a
  model that takes only adaptive thinking, a call's `output_config` is merged
  over the model's, and Claude Haiku 4.5 and Sonnet 4.5 reject `effort:`
  before the request.
- Requests check more of the model profile before they are sent: OpenAI and
  xAI reasoning efforts, Gemini thinking levels, and built-in tools a Gemini
  model lacks.
- `base_url: nil` in any provider client's `new/1` means "not set", so the
  client falls back to application config, then the default URL.
- Anthropic and Google message and tool conversion, and model-name lookups,
  no longer turn unexpected exceptions into errors; only invalid input returns
  `{:error, %Core.Error{}}`.
- A bare tool name as `tool_choice:` forces that function on OpenAI, xAI,
  Moonshot and DeepSeek, and `:any` means `:required`.
- Structured output's tool strategy forces the schema tool only where the
  model allows a forced tool choice; on Kimi or DeepSeek with thinking on,
  Z.ai, and Claude models that take only `:auto` or `:none`, it offers the
  tool without forcing it.
- Kimi K2.6 and K2.5 get a response schema as JSON mode with the schema in a
  system message, so an agent's `response_schema` works on them.
- `RateLimiter.TokenBucket` children use their `:name` (or `:id`) as child
  id, so several named buckets fit in one supervisor.
- Z.ai PDF blocks are sent as Z.ai's documented `file` part, with a
  `file_url`, or `file_data` holding a data URL and the block's `filename`.

#### Compaction engine

- The automatic-compaction limit (`maximum_auto_compactions_per_root_turn`)
  and the overflow retry count are per root turn: a new `root_turn_id` starts
  them again. `Compaction.State` has a `root_turn_id` field.
- The compaction constructors no longer swallow arbitrary exceptions; only
  missing required compaction fields turn into `{:error, ...}`.

### Fixed

#### Agents

- A `BeamWeaver.Schema` field takes a JSON Schema map as its type, such as
  `field :due, %{"type" => "string", "format" => "date"}`. Before, the module
  didn't compile.
- A `nullable: true` field of a `BeamWeaver.Schema` lists `nil` among its
  `enum:` values, and a nullable union or `:any` field keeps its other values
  instead of allowing only `"null"`.
- Model-call error details and structured-output traces show a model given as
  a string by that string instead of `"nil"`.
- `Messages.Utils.trim/2` treats `include_system: nil` like leaving the option
  out instead of raising `BadBooleanError`.
- An agent whose model can't take images or PDFs keeps working once its thread
  holds them, such as after `read_file` returned one: the model gets a notice
  in their place instead of failing with `:unsupported_feature`.
- Approximate token counting counts a file, audio or video block as one media
  item, as it counts an image, instead of by its base64 data.
- Tool calls without an id, and large tool results without a tool call id, get
  unique generated names, so a second large result of a tool is saved to its
  own file instead of staying in the thread.
- The notice that replaces a large tool result or user message mentions
  `... [N lines truncated] ...` only when the preview leaves lines out, and
  says when it cuts lines longer than 1,000 characters.
- The filesystem section of the system prompt describes only the tools the
  model is offered, so a tool removed with `exclude_tools` isn't mentioned.
- A model id with colons of its own, such as an OpenAI fine-tune's `ft:...` id,
  gets its provider's profile, and registering a profile for it no longer
  raises `ArgumentError`.
- Structured output after a tool loop works on Anthropic and Gemini.
- Agents from `build/1` use a call's `checkpointer:`, `store:` and `cache:` in
  `invoke/3`, `stream_events/3`, `resume/3` and `get_state/2`, so a second call
  continues the thread.
- A `tools do` block keeps the options of `tool Mod, opts`, and a toolkit
  module there adds the tools its `tools/1` returns instead of raising
  `UndefinedFunctionError`.
- Agent modules accept a `%BeamWeaver.Graph.Command{}` input to `invoke/2` and
  `stream_events/2`, and an agent's `input_schema` checks new input only, so a
  `Command` or an empty input continues a thread.
- An agent with a response schema returns each turn's own structured answer on
  a checkpointed thread, not an earlier turn's.
- A malformed or truncated tool call gets an error tool message, so the model
  learns it failed and providers that need every call answered accept the next
  request.

#### Middleware

- The notices for tool results and messages saved to files name `read_file`
  only when the call offers that tool.
- A `wrap_model_call` middleware can set the request's model to a
  `"provider:model"` string with `ModelRequest.override/2`.
- `Summarization.new/1` raises `ArgumentError` for a `keep` given as a list,
  `{:all, …}` or `{:any, …}`, instead of failing at the first summary.
- `ToolEmulator` and `ToolRetry` take tool modules in `tools:`. Before, a
  module matched no tool.
- A model call whose middleware rewrites the thread, with an `Overwrite` of
  `messages` in an `ExtendedModelResponse` command, keeps the other messages
  the call saves.
- The `compact_conversation` tool's summary call is retried as automatic
  summarization's is.
- An empty memory file, such as an empty `AGENTS.md`, is left out of the system
  prompt.
- `BeamWeaver.Agent.Middleware.ShellTool` works in an agent, reuses its session
  when a paused run resumes, and stops a session idle for `:idle_timeout` (a
  new option), so a run that never reaches `after_agent` doesn't leak one.
- Middleware hooks that return `{:jump, :model, update}` or
  `{:jump, :tools, update}` work instead of looping until `:recursion_limit`.
  A jump to `:model` or `:end` (or a halt) from an `after_model` hook skips the
  `after_model` hooks left.
- `ModelFallback` accepts `"provider:model"` strings in `fallbacks:`.
- `thread_limit` in `ModelCallLimit` and `ToolCallLimit` counts every call on a
  thread across `invoke/2` calls (it needs a checkpointer), not just one run.
- `ModelCallLimit`'s end message lists only the limits that were reached, and
  `ToolCallLimit`'s names the exceeded limit also when a batch has both
  allowed and refused calls.
- `ToolRetry`'s `on_failure: :continue` message names the tool's error once.
- `PII.stream_transform/1` passes a whole agent stream through without
  doubling the text in message chunks or emptying it in tokens.
- `overflow_recovery` keeps the clipped tool results in the thread when the
  retry succeeds, so the next call doesn't overflow again.
- The summary calls of `Summarization` and `compact_conversation` no longer
  send their trace metadata as the provider request's `metadata`, which xAI
  and DeepSeek's Responses API refused with `:unsupported_model_param`.
- An agent with `compact_conversation` keeps its thread after the model
  compacts it: the compaction applies once, before automatic summarization,
  and is saved with the checkpoints when the run pauses first.
- `ToolCallLimit` with `exit_behavior: :end` answers every call of the batch,
  so the next turn no longer fails with `:invalid_chat_history`.

#### Subagents and deep agents

- A `SKILL.md` loads when `allowed-tools` is a YAML list, `metadata` is `{}`, a
  value is an empty string, or the description is over 1,024 bytes (it is cut,
  with a logged warning). `allowed-tools: {}` is an error, and a field over its
  size limit fails with a message naming the field, its size and the limit.
- The general-purpose subagent gets the parent's `tool_descriptions`,
  capability profile and `exclude_tools`, and the parent's own `Filesystem`
  (with its permissions), `Skills`, `Summarization`, `CompactConversation` and
  `ToolCallNormalization` entries. Before, it could write a file the parent was
  denied or call a tool the parent was never offered.
- The general-purpose subagent and subagents with
  `base_middleware: [:deepagents]` summarize only when the agent does, with its
  `summarization:` settings.
- `list_async_tasks` refreshes the status of an `interrupted` task, and each
  async subagent tool offers only the arguments it reads, with
  `start_async_task` requiring `subagent_type`.
- A subagent's own middleware replaces the `base_middleware:` entry of the same
  module instead of failing the build or running both.
- A subagent neither starts with nor overwrites the parent's private state,
  such as limit counts or keys declared with `Graph.private_channel/2`, also
  through the `task` tool of `BeamWeaver.Tools.Subagents`.
- A `%Agent.Subagent.Compiled{}` with `capture_output: :key` no longer crashes
  on its first `task` call.
- `skills ["/skills"]` titles the folder `**Skills**` in the system prompt
  instead of `**Skills Skills**`.
- `TodoList.new(tool_name: "plan")` names `plan` in its default prompt and
  errors instead of `write_todos`.
- Agent modules that name each other, or themselves, as subagents no longer run
  out of memory on their first call.
- A `:structured_once` or `:research_then_generate` subagent can list its own
  `ModelCallLimit`, which replaces the mode's one-call limit.

#### Human review, checkpoints and resuming

- `Checkpoint.put_many/3` on Ecto keeps the task id of a
  `{task_id, channel, value}` write and accepts
  `{task_id, channel, value, path}`, as ETS does.
- A new message sent to a thread whose tool calls wait for review cancels the
  review (a subagent's too): each call that hasn't run gets a failed result
  right after it, as Anthropic and Chat Completions require.
- After `resume_review/3` (or `resume/2`) fails because the resumed node
  returned an error, such as `:invalid_human_decision`, the interrupt stays
  pending and the next valid resume completes the run.
- `resume/2` continues past static breakpoints (`interrupt_before`,
  `interrupt_after`) on graphs and agents, also when the breakpoint is inside
  a subgraph.
- `Compiled.update_state/4` on a paused thread keeps it paused: the next
  `resume/2` runs the paused node on the updated state, and a subgraph or
  subagent paused inside it continues where it paused.
- A struct, such as a `Date`, works as a resume value instead of raising
  `Protocol.UndefinedError`.
- The checkpoint facade loads a saver's module before checking its callbacks,
  so a saver built as a struct literal in dev or test works.
- `Checkpoint.ETS.delete_thread/2` also removes pending writes whose
  checkpoint is already gone.
- A thread saved with `BeamWeaver.Checkpoint.Ecto` (Postgres or SQLite) reads
  back with the keys `Checkpoint.ETS` gives, maps nested in its values
  included, instead of string keys.
- On `Checkpoint.Ecto`, a `Send` task that paused or failed can be continued;
  before, resuming it paused again forever and finished `Send` tasks ran a
  second time.
- `update_state/4` and `bulk_update_state/4` keep join progress, the run
  counts of guarded edges (`max_runs:`) and private keys saved with the
  thread, so a join waiting on a branch still fires.
- `update_state/4` on a thread whose last step failed no longer applies the
  finished nodes' writes twice or runs them again; continuing runs the failed
  node.
- `update_state/4` without `as_node:` on `Checkpoint.Ecto` routes from the node
  that ran last, as on `Checkpoint.ETS`; `next` became `[]`.
- `update_state/4` on a thread stopped at a breakpoint keeps the nodes that
  other branches or a `Command`'s `goto` had put in `next`.
- `%Command{resume: ..., update: ...}` keeps its update when the resumed node
  pauses again, so the updates of several resumes all survive, and
  `DeltaChannel` keys keep it after a reload.
- A run started with `%Command{update: ...}` and no `resume` saves the update
  for `DeltaChannel` keys as well.
- New input to a thread whose last step stopped partway (a node failed or
  paused) is saved into that step before it continues, so it stays when the
  step stops again. See [Durable
  Execution](docs/durable_execution.md#what-survives-a-crash).
- A resume map keyed by interrupt id keeps the answers a paused task already
  used, so a task paused at its second `Graph.interrupt/1` no longer asks its
  first question again when another task's interrupt is answered.
- Resuming from a stopped checkpoint earlier than the thread's latest saves to
  a new checkpoint, so the answers no longer reach a branch that had already
  gone on from it.
- A subgraph that pauses in several nodes at once pauses the parent with every
  pause, and a map from their ids resumes them all at once or one at a time;
  before, every form of resume failed with `:invalid_resume`.
- `bulk_update_state/4` schedules what comes next as `update_state/4` does:
  the nodes after each superstep's `as_node:` (or the node that ran last) are
  in `next`, and a task waiting at a breakpoint stays.
- `bulk_update_state/4` on a thread whose last step stopped partway saves each
  superstep into that step, as `update_state/4` does, so its pauses and failed
  node stay and the nodes after the finished ones run.
- `bulk_update_state/4` checks every superstep before it saves any: one that
  isn't a list fails the call with `:invalid_update` and nothing is saved.
- `%Command{resume: ..., goto: ...}` on a thread whose last step stopped
  partway, or that waits at a breakpoint, saves the `goto`'s nodes into that
  step, so one that pauses or fails runs on the next resume.
- A config with `checkpoint_id: ""` (or `nil`) means the thread's latest
  checkpoint, as no id does; before, `get_state/2` returned `:error` and
  `invoke` started the thread over.

#### Graphs

- A `DeltaChannel` key whose reducer raises fails the step with
  `:invalid_update`, as a reducer key does, instead of raising out of
  `invoke/3`.
- `Graph.add_join/4`, and `deps:` with several nodes, fire when the nodes
  they wait on finish in different steps or the thread continues after a
  failed or paused step; before, the joined node silently never ran.
- `Graph.Messages.remove/1` deletes a message by id instead of raising
  `ArgumentError`; removing an id that isn't in the list fails the run with
  `:invalid_update`.
- An agent module (`use BeamWeaver.Agent`) works as a graph node, run as a
  subgraph with its checkpoints, interrupts and events in the parent's run;
  before, the run failed with a `:node_exception`.
- `Graph.validation_report/2` and `validate_static: true` follow the targets a
  node lists in `destinations:`, so a node that routes with `Command` or
  `Send` is no longer reported as a dead end.
- The graph's internal `:__node_outputs__` and `:__edge_runs__` keys no longer
  leak into node state, `runtime.previous_state`, events, cache keys,
  interrupts or the state that edge conditions receive.
- `runtime.execution.run_id` is set; it was always `nil`.
- Graph `:node_timeout` errors and telemetry always report the node's
  configured timeout.
- Continuing a thread whose last step stopped partway, on an error or an
  interrupt, runs what comes after the nodes that finished in that step:
  their edges, `Command` gotos, `Send`s and guarded edges.
- A `Command` with `goto` replaces only the edges of the node that returned
  it, so a parallel branch in the same step no longer stops there.
- Identical `Send`s in one step (same node, update and timeout) each run as a
  task of their own; they ran once.
- Continuing a thread whose last step stopped partway runs every unfinished
  `Send` task again, and `get_state/2` lists them all in `next_tasks`.
- A `when:` function or `deps:` condition that raises fails the run with
  `{:error, %BeamWeaver.Core.Error{type: :edge_exception}}` instead of raising
  out of `invoke/3`, `resume/3` and `update_state/4`.
- A subgraph whose task runs again, on the node's `retry:` or when the parent
  thread continues after a failure or a crash, continues its own run instead
  of merging the parent's state in a second time.
- Replaying a parent graph from an earlier checkpoint starts its subgraphs
  afresh instead of on top of their earlier runs.
- A subgraph node without an `input:` projection or `input_schema` gets the
  parent's public state only, not its private keys.
- A run reads its thread's checkpoint once, when it starts, instead of before
  every checkpoint write.
- `Graph.ServerInfo.new/1` keeps a user's `is_authenticated: false`; it
  became `nil`.
- A `DeltaChannel` key reads back each write as it was written: a reload no
  longer splits a list write into its items or loses a `nil` write.
- Messages written to a `Messages.delta_channel/1` key get their ids once, so
  `Messages.remove/1` with an id the run returned removes the message.
- A key changed from a `DeltaChannel` to another channel keeps its value, and
  the next run adds to it.
- `get_state/2` and `get_state_history/3` on a thread with `DeltaChannel` keys
  no longer read back to the thread's first checkpoint for every key, which
  made long histories very slow, most of all on `Checkpoint.Ecto`.

#### Streaming

- A model's typed event stream ends with one `Done` carrying the final usage
  on Chat Completions streams and Anthropic, and Gemini's `Done` carries the
  usage too.
- `stream_events/3` without `live: true` returns events in order, no longer
  wraps model events in `Events.Custom` or repeats a node's `Message`, and
  follows `stream_mode:`.
- Live streams send each subgraph event once; they sent it twice.
- A live stream whose top-level run ends with a `Command` for a parent graph
  (`graph: :parent`) ends with an `Error` event holding the `:parent_command`
  error that `invoke/3` returns, not with a `Debug` event.
- A live stream no longer leaves a `{ref, {:beam_weaver_mux_done, pid, :ok}}`
  message in the reading process's mailbox.
- `BeamWeaver.Stream.Subgraphs.from_events/2` and
  `BeamWeaver.Stream.Lifecycle.from_events/2` report a subgraph that failed as
  `:failed` and one that paused as `:interrupted`; both were `:completed`.
- An agent's stream no longer has `Debug` events `%{type: :producer_start}`
  and `%{type: :producer_stop}` for each streamed model call on OpenAI, xAI,
  Kimi, Z.ai and DeepSeek models.
- `stream_mode: :messages` streams the messages that several nodes write in
  one step to a `Graph.Messages.delta_channel/1` key; it streamed none.

#### Memory, storage and caching

- `Memory.search/3` on ETS matches a filter on a struct field by the struct's
  JSON form, as Postgres stores it, instead of raising
  `UndefinedFunctionError`.
- `Migrations.up/1` on Postgres with `version: 0` migrates nothing, as on
  SQLite, instead of creating tables and raising.
- `Checkpoint.Ecto` gives a checkpoint saved without an id a UUIDv7 id. The
  ids came from a counter that restarts with the VM, so a thread continued
  after a restart or a deploy overwrote its older checkpoints.
- Encryption with `Serialization.Encrypted` works in `Checkpoint.Ecto` and
  `Cache.Ecto`; every write failed with `:invalid_serialization_key`.
- `Memory.ETS` removes a record's embeddings when it prunes, sweeps or skips
  the expired record.
- A graph node with `cache:` works with `BeamWeaver.Cache.Ecto`; every run
  failed with `:unsupported_serialization_type`.
- `Checkpoint.ETS` reads and saves checkpoints faster: it reads only the
  thread and keys it is asked for instead of copying whole tables.
- A read that refreshes a record's TTL (`refresh_ttl`) no longer undoes a
  `put` that runs at the same time, in `Memory.ETS` and `Memory.Ecto`.
- `Memory.search(store, [])` on `Memory.Ecto` returns the records of every
  namespace, as on `Memory.ETS`; it returned `[]`.
- `Serialization.load/2` returns a `:serialization_error` for an encoded atom
  whose value isn't a string and for an encoded tuple whose items aren't a
  list, instead of raising.
- SQLite checkpoint migrations given the singular
  `adapter: {:checkpoint, checkpoints_table: ..., writes_table: ...}` check
  the version of those tables, so a rollback removes them.
- `Memory.search/3` with `filter:` skips records whose value isn't a map
  instead of raising `FunctionClauseError` in the ETS store.
- `Memory.get_many/3` returns a stored `{:error, _}` value as that value
  instead of reporting a failed read.
- A cached graph node's `ttl:` counts from the run that saved the entry; a
  cache hit no longer writes the entry again.
- A node whose `error_handler:` supplied the result is not cached.
- `BeamWeaver.Memory.list_namespaces/2` on `Memory.Ecto` no longer lists a
  namespace whose records have all expired.
- Reading an expired memory record or cache entry, or sweeping expired ones
  in `Memory.ETS` or `Cache.ETS`, no longer deletes a value put under the same
  key at the same moment.
- A checkpoint holding a value that can't be rebuilt any more loads: a struct
  whose tag or module is gone comes back as a map of its fields and an unknown
  atom as a string, with a warning. `BeamWeaver.Serialization.load/2` behaves
  the same way. See [Serialization](docs/storage.md#serialization).
- `Checkpoint.prune/3` keeps what a thread's `DeltaChannel` keys still read,
  leaves `fork_at/4` working, and also removes the checkpoints of subgraph
  calls that finished.
- `Checkpoint.delete_for_runs/2` makes a checkpoint whose parent it deletes
  the first of its thread, as `Checkpoint.prune/3` does, so `fork_at/4` can
  copy it.
- `Checkpoint.ETS` keeps a checkpoint's parent when the same checkpoint is put
  again, as `Checkpoint.Ecto` does; putting it under one of its descendants
  made reading delta history hang.

#### Tracing and telemetry

- Trace redaction keeps a map or pair key that isn't a string, atom, number or
  charlist, such as `{:a, 1}`, instead of raising `Protocol.UndefinedError`.
- A traced model call whose `response_metadata.transport` isn't a map records
  no request id instead of raising `FunctionClauseError`.
- The local trace store no longer grows without bound, and a run whose
  process exits before finishing it, such as a task killed at its timeout,
  ends with `status: :error` and `error: %{kind: :exit, reason: ...}` instead
  of staying `:running`.
- Exporters, such as WeaveScope's, get an `:error` event for such a run;
  WeaveScope showed it as running forever.
- The WeaveScope export queue uploads the traces still queued when it stops,
  such as at application shutdown, instead of dropping them.
- A graph run that fails before its first step closes its trace run.
- Traced calls spend much less time redacting secrets, with the same result.
- An exporter set in config (`config :beam_weaver, tracing: [exporter: ...]`)
  or in a call's `exporter:` option gets events even before anything has
  loaded its module, as in development and tests.
- The WeaveScope exporter exports a run kind given as an atom, such as
  `:generation`, as it does the string, instead of as `"span"`.

#### Retrieval, prompts and parsers

- A vector store `$contain` filter ignores case on ETS, as on Postgres, and on
  Postgres takes `%`, `_` and `\` in the value literally.
- On Postgres, `$like` and `$contain` match only string values (and
  `$contain` a list element), as on ETS, instead of matching other values by
  their JSON text.
- The ETS vector store's `$like` filter matches the whole value, as Postgres
  `ILIKE` does, instead of also matching any value containing the pattern.
- An ETS vector search scores embeddings with very large or very small values
  instead of raising `ArithmeticError`.
- `VectorStore.add_documents/3` and `from_documents/3` accept the stream that
  `TextSplitter.split_documents/2` returns, or any enumerable of documents.
- `VectorStore.as_retriever(store, search_type: :mmr, mmr_lambda: x)` uses `x`
  instead of always 0.5, and `mmr_lambda:` passed to `Retriever.retrieve/3`
  overrides it.
- `TextSplitter.html_headers/1` keeps headings that aren't in `headers:` as
  section text instead of filing them under a `nil` metadata key.
- `TextSplitter.markdown_syntax/1` gives every chunk its document's metadata,
  not only the last.
- Pinned requests to an IPv6 address, such as `split_url/3` on a host that
  resolves to one, connect instead of failing with `:nxdomain`.
- Pretty-printed JSON, such as the JSON-object mode instruction's schema,
  handles atom values and structs such as `DateTime` instead of raising.

#### Tools

- A `nullable: true` tool argument, or a type list such as
  `["object", "null"]`, accepts `nil` (also with `enum:`) and checks any other
  value like the plain type, objects and lists included.
- `OpenAI.ToolCalling.function/2` with `strict: true` closes the schema of a
  tool given as a module, as it does for a struct.
- `ValidationNode.new/2`, and so `validate_tools true`, takes tools given as
  structs of a `use BeamWeaver.Tool` module instead of raising.
- `Core.Tool.invoke/3` with a tool-call input (`type: "tool_call"`) returns a
  tool's `%Graph.Command{}` as it is, not as a tool message.
- A struct given for an `"object"` argument fails the input check with
  `:invalid_input` instead of raising `Protocol.UndefinedError`.
- Tool modules may return `{:error, reason}` with any reason, or a bare value,
  like function tools, instead of raising `WithClauseError`; a string reason
  is the error message the model reads.
- Tool error messages no longer end the error's own sentence with a second
  period.
- An agent keeps the artifact of a `response_format :content_and_artifact`
  tool, such as `Retriever.as_tool/2`'s documents, in the tool message's
  `metadata.artifact` instead of dropping it.
- A tool module without `description` is described by its `@moduledoc`
  instead of an empty description.
- A property typed `"null"` in a tool input or structured-output schema
  accepts only `nil` instead of any value.
- A `$ref` to an integer-keyed entry, such as `#/$defs/400`, always resolves,
  whichever atoms the VM has created.

#### Filesystem and sandboxes

- `Sandbox.read/3` and `Sandbox.ls/3` on a Docker sandbox return an error for
  a relative or invalid path instead of raising, and every Docker file
  operation returns `"invalid_path"` for a path that isn't valid UTF-8.
- A `Composite` route below a folder of its default backend, such as
  `/workspace/memories/`, is listed and searched from every folder above it;
  `ls /` no longer shows it as an entry of `/`.
- Docker `grep` matches globs that have `/`, such as `src/**/*.py`, skips
  binary files and `.git` folders, and returns an error for a missing path, a
  failed search or a relative path instead of `[]` or raising.
- Docker's file operations no longer cut a large `grep`, `ls` or `read` result
  at `max_output_bytes`.
- The local sandbox's `read/3` splits lines as the other backends do (final
  newline, `\r\n` and `\r`, negative `offset`) and reads 2,000 lines by
  default instead of the whole file.
- `Filesystem.Composite` returns the error of a backend that fails when it
  lists or searches `/`, instead of results that look complete.
- `grep` on `Filesystem.Local`, `Filesystem.LocalShell` and `Sandbox.Local`
  skips binary files and `.git` folders, so one binary match no longer fails
  the whole call.
- `Sandbox.Docker.edit/5` changes only the text it replaces instead of
  rewriting the file from a 2,000-line read; `write/4` of an existing file
  returns `"file already exists"`, `upload_files/3` replaces existing files,
  and one bad path in `upload_files/3` or `download_files/3` fails only its
  own file.
- On `Filesystem.State`, the default filesystem, changes to different files in
  one model turn all apply instead of the last call undoing the others. A
  second `write_file` or `edit_file` on a path an earlier call of the same turn
  changes is now refused, on every backend.
- Shell commands that pass their timeout, or whose calling process dies, are
  stopped with every process they started (shell tool,
  `Filesystem.LocalShell`, `Sandbox.Local`, `Sandbox.Docker`) instead of
  running on in the background; `LocalShell` and `Sandbox.Local` commands read
  EOF on stdin.
- `Filesystem.Store` on `Memory.Ecto` keeps its writes, returns a failed store
  read or write as an error, saves only the file a write changes, and no
  longer sees the files of nested namespaces.
- `glob` on `Filesystem.State` and `Filesystem.Store` finds top-level files for
  patterns such as `**/*.md`.
- A `Filesystem.State` backend under a `Composite` route keeps `/scratch/x.md`
  under its full path instead of `/x.md`, and `ls`, `glob` and `grep` from `/`
  no longer return its files twice. Routed backends get the route's prefix as
  the `:route_prefix` option.
- `Filesystem.State.download_files/3` returns `"invalid_file_data"` for content
  that isn't valid base64 instead of raising.
- `glob` and `grep` on `Filesystem.Local` and `Filesystem.LocalShell` work in a
  directory whose path has a glob character, such as `/srv/notes [draft]`.
- A malformed pattern, such as `{a,b`, makes `glob` and `grep` on
  `Filesystem.Local`, `Filesystem.LocalShell` and `Sandbox.Local` return
  `"invalid_pattern"` instead of raising.
- A shell `Session` survives a non-UTF-8 exported variable, which made every
  later command fail until the session restarted.
- `Sandbox.Local.read/3` returns a binary file whole, as `Sandbox.Docker` and
  `Filesystem.Local` do, instead of cutting it to 2000 bytes.
- `Sandbox.Local` reports reading or editing a directory as `"is_directory"`
  instead of `":eisdir"`, and `edit/5` with an empty old string reports
  `"string not found"`, as the other backends do.

#### Models and providers

- Gemini sends a file block given by `url:`, and image, audio and video
  blocks given by `file_id:`, as file data with that URI; they were left out
  of the request.
- `ContextBudget` works with Claude Haiku 5.5 and Sonnet 5.5, counting the
  requested output against their shared 1M-token window. Every budgeted call
  failed with `:unknown_context_limit`.
- `reasoning: %{effort: nil}` counts as no effort: OpenAI, xAI and DeepSeek
  Responses requests leave the nil field (and an empty `reasoning`) out of the
  body and fall back to `reasoning_effort:`, and GPT-6 requests no longer fail
  with "GPT-6 reasoning effort is not supported by this model".
- DeepSeek's typed Chat Completions stream ends with one `Message` carrying
  the usage and one `Done`, also when the finish reason and usage come in
  separate chunks, and a stream without choices ends with its `Done` instead
  of an `Error`.
- `Models.init_chat_model/2`, `init_embeddings/2` and `init_decision_model/2`
  return an `:invalid_model` error when `:model` is not an identifier; a
  keyword list or map never returned, and an integer raised.
- `Provider.Replay.restore/2` returns an `:invalid_provider_replay` error for
  an OpenAI reasoning block with an unknown provider field instead of raising.
- Chat Completions requests (OpenAI, xAI, Moonshot, Z.ai and
  OpenAI-compatible services) send a tool result's images and PDFs in a user
  message right after the tool results. OpenAI and xAI dropped them, and
  Moonshot and Z.ai sent their `inspect/1` text, base64 data included.
- Gemini gets a PDF from a tool result as a part with its MIME type, as it
  gets images, instead of as base64 data inside the response JSON.
- OpenAI and xAI model profiles, and the `grok-*` family profile, list PDF
  input, and the fake chat model's profile lists image and PDF input.
- Context overflow errors from OpenAI-compatible servers (llama.cpp, LiteLLM,
  Text Generation Inference, and a 413 or 422 saying the prompt is too long)
  are `:context_overflow`, so `overflow_recovery` acts on them. It also
  recognizes those wordings in an error of another type, such as one a proxy
  passes on.
- An xAI error keeps xAI's message, such as "Incorrect API key provided",
  instead of "xAI request failed with HTTP 400".
- Claude Opus 4.8, Fable 5 and Mythos 5 take a system message partway
  through a conversation; they refused it with `:invalid_messages`.
- Claude Sonnet 4.6's profile and default `max_tokens` allow 128,000 output
  tokens, Anthropic's limit; both were 64,000.
- Anthropic agents that stream (`stream: true`) can use tools, and their
  streamed reply has the same content as a non-streamed one, thinking
  signature included.
- Agents whose model streams keep the whole reply, with its reasoning,
  `usage_metadata` and provider metadata, on OpenAI Chat Completions,
  Anthropic, Moonshot (Kimi), Z.ai and xAI Chat Completions models: their
  typed event stream (`ChatModel.stream_typed_events/3` and `stream_events/3`)
  ends with a `Message` event holding the complete reply, then one `Done`.
  Agents on Kimi thinking models now send the reasoning back with tool
  results, as Kimi requires.
- xAI's `ChatCompletionsModel.stream_response/3` keeps the reply's
  `reasoning_content` and `citations` metadata, and OpenAI's Chat Completions
  `stream_response/3` keeps a streamed refusal and every token's log
  probabilities.
- A streamed Kimi reply holds its reasoning in one `:reasoning` block instead
  of one block per streamed piece.
- `Models.cached/3`, `with_rate_limiter/2` and `bind_tools/3` work when the
  call is traced, as every call inside an agent or graph is; tracing raised
  `Protocol.UndefinedError`.
- OpenAI Chat Completions, response retrieval, input-item listing, response
  compaction and moderation requests, and `OpenAI.Images.generate/2`, honor a
  custom endpoint or `:base_url` instead of always calling `api.openai.com`.
  `OpenAI.Client` gained `:base_url` and `:chat_completions_endpoint`, and
  `OpenAI.Client.endpoint/2` takes a client or base URL.
- `init_embeddings/2` for OpenAI and xAI reads the API key and base URL from
  the provider's config group; it sent no `Authorization` header.
- Moonshot, Z.ai and xAI clients no longer send per-call `:headers` twice.
- A Responses API built-in tool (such as `%{"type" => "web_search"}`) given
  to a Chat Completions model returns an `:unsupported_feature` error instead
  of becoming an empty function tool or raising.
- A content block a provider or API can't take, such as video, audio given by
  URL or a citation, returns an error instead of raising: `:unsupported_feature`
  on OpenAI, xAI, DeepSeek and Moonshot, `:invalid_content_block` on Anthropic,
  and an `Error` on Z.ai. Anthropic sends an image given by `file_id` as a
  file source.
- Agents with Anthropic server tools, such as `Anthropic.Tools.web_search/1`,
  work past the first search: the next request sends the `server_tool_use`
  and `*_tool_result` blocks exactly as Anthropic returned them. A
  non-streamed reply saved by an earlier version lacks the result blocks, and
  sending it returns an `:invalid_content_block` error.
- A reply sent to another provider or API, as after a model fallback, goes as
  its text and tool calls, without its reasoning; OpenAI and Anthropic
  rejected such requests. Replies sent back to their own provider are
  unchanged.
- Kimi K2.6 accepts `tool_choice: :required` with thinking disabled.
- Z.ai checks `thinking` and `reasoning_effort` against each GLM model's
  profile, so GLM-5.3 is no longer checked against GLM-5.2's list.
- A Z.ai model created with `stop:` sends those stop sequences; only a call's
  own `stop:` was sent.
- Kimi quota errors (`exceeded_current_quota_error`, sent as the error's
  `type` with HTTP 429 or 403) are `:billing_exhausted` and aren't retried;
  one without a `code` field was retried as a rate limit.
- Kimi's "prompt tokens + max_tokens exceeds the model specification" error
  is a `:context_overflow`.
- Z.ai errors are classified by their documented codes, given as a string or
  a number, with or without streaming: 1301 is a `:content_filter`, 1261
  (prompt too long) a `:context_overflow`, and the plan and usage limits,
  1308 to 1321, a `:billing_exhausted` error that isn't retried.
- OpenAI's spend and usage limits (`credit_balance_exhausted`,
  `organization_spend_limit_exceeded`, `project_spend_limit_exceeded`,
  `organization_usage_limit_exceeded`) are `:billing_exhausted` and aren't
  retried.
- A Gemini 429 (`RESOURCE_EXHAUSTED`) whose message names a token limit is
  retried as a rate limit instead of counting as a `:context_overflow`.
- `Google.Client` functions, and so a Google model's calls, use a per-call
  `:api_key`, `:transport` and `:transport_opts` over the client's own; they
  were ignored.
- OpenAI and xAI Chat Completions requests send one output cap, the call's or
  else the model's: as `max_completion_tokens` on GPT-5, GPT-6 and o-series
  models, and under the name it was given on others. A model created with
  `max_completion_tokens:` sent both `max_tokens` and `max_completion_tokens`.
- The `expected` hint for a bare GLM or DeepSeek id names the id you gave,
  such as `"zai:glm-5.3"`, instead of a fixed model.
- Requests to an IPv6 address, such as a model server at
  `http://[::1]:8000/v1`, connect through `Transport.ReqFinch` and unpinned
  `Transport.Safe` requests instead of failing with `:nxdomain`.
- A response whose headers pass `Transport.ReqFinch`'s `max_header_list_size`
  (which `Transport.Safe` sets from `:max_response_header_bytes`) fails with
  `:response_headers_too_large` instead of `:transport_failure`.
- Agents on xAI reasoning models, such as `xai:grok-4.20-0309-reasoning`,
  keep their reasoning between turns: the request asks for the encrypted
  reasoning and sends it back unchanged. The model lost its earlier thinking
  after every tool call and could loop until a call limit stopped it.
- A file part with a nested `file` map, as Z.ai and OpenAI Chat Completions
  write it, and Z.ai's older `file_url` part, become a file block with that
  URL, and a data URL gives the block its base64 payload and media type. The
  URL was dropped, so Z.ai rejected the block.
- Converting a message map (`Core.Message.from/1`) returns an
  `:invalid_message` error when `metadata`, `response_metadata` or
  `usage_metadata` isn't a map or `server_tool_calls` or `server_tool_results`
  isn't a list, and an `:invalid_tool_call` error when `tool_calls` isn't a
  list. Such fields were accepted or dropped.
- `use_previous_response_id: true` works on xAI's Responses API and on OpenAI
  models made with `init_chat_model/2`. A reply made with `store: false` is no
  longer used as `previous_response_id`; the whole conversation is sent
  instead.
- Replies streamed from xAI's Responses API with `ChatModel.stream_events/3`,
  as in a streaming agent, carry xAI's metadata (`provider: :xai`) instead of
  OpenAI's, and xAI replies record their API in `response_metadata.api`.
- A model stream that the provider breaks off with an error after its 200
  response fails the call with the error the same failure gets without
  streaming, so `ModelRetry` retries it, or not, as it would without
  streaming. Anthropic, the Responses APIs, Moonshot, Z.ai and DeepSeek
  returned the cut-off reply as a success, and the text stream of `stream/3`
  just ended.
- `Provider.Outcome.classify/1` recognizes the documented ways a reply ends
  early, streamed or not: content-filter stops (an `incomplete` Responses
  reply with the `content_filter` reason, Gemini's `RECITATION`, `BLOCKLIST`
  and similar) are `turn_disposition: :filtered`, Anthropic's `refusal` stop
  reason is `:refusal`, context-window stops are `:context_limit`, and xAI's
  `max_time_limit` is `:budget_exhausted`.
- Gemini replies go back with the thought signature of their text, which
  Gemini 3 uses to keep its reasoning across turns; only a reply restored from
  its `Provider.Replay` projection kept it.
- OpenAI Responses requests send an assistant message's id only when the API
  issued it (`msg_...`). OpenAI refused a request with an assistant message
  built by the app or added by middleware.
- Every provider sends an invalid tool call back next to the error the agent
  answers it with, as OpenAI Chat Completions, xAI and DeepSeek already did.
- An OpenAI Responses stream whose item reports a later `output_index` on its
  later events, as after built-in tool calls, gives one output item and one
  content block instead of a duplicate, unfinished item.
- A replayed OpenAI Responses `function_call` keeps its `namespace`, `status`
  and `async` flag.
- An Anthropic-style image given by URL or file id (`source` of type `"url"`
  or `"file"`) keeps its source instead of becoming an empty image.
- `count_tokens_approximately/2` and OpenAI's token counting count a tool
  given as a module or `%Tool{}` struct by its name, description and
  parameters, as the provider gets it.
- `Models.ProfileRegistry.fetch(:deepseek, nil)` returns an
  `:unsupported_model` error instead of raising `FunctionClauseError`.
- `DeepSeek.Client.new/1` derives the beta and Anthropic endpoints correctly
  from a base URL with non-ASCII characters.
- Structured-output parsing reports a truncated answer when only the response
  metadata says so (`finish_reason`, `incomplete_details` or `status`),
  instead of failing it as invalid JSON.

#### Compaction engine

- `ContextBudget.new/3` says when `:local_tokenizer_v1` falls back to byte
  counting, in the budget's new `fallback_reason` field (`:no_tokenizer` or
  `:tokenizer_failed`).
- `Compaction.compact/2` returns `:current_input_item_too_large` when every
  event is protected, instead of `:nothing_to_compact` or reusing a previous
  summary without calling the model.
- `Compaction.compact/2` keeps a lane's last compaction when the state was
  built with `State.new/1` and `record_success`, so automatic compaction
  doesn't run again right away.
- The compaction engine's `:rapid_refill` guard works: an
  `:ineffective_compaction` error carries the lane's state with the attempt
  recorded in `details.anti_thrash`, and saving it pauses automatic
  compaction until new context arrives.

#### Testing

- `Models.init_embeddings("fake:embedding", mode: :random)` passes `mode:` to
  the fake embedding model.
- A replay cassette keeps empty strings, empty lists and lists of integers as
  written, and a cassette that isn't valid YAML returns `:invalid_cassette`
  instead of raising.

### Documentation

- The guides are rewritten and reorganized: a Quickstart that builds a first
  agent without an API key, a Concepts page, one page per feature, and new
  pages on testing, caching, storage, graph state and memory files. Each
  provider page has a model table generated from the model profiles, and old
  page names redirect to their new pages.
- Every Elixir example in the README, the guides and the main module docs runs
  or compiles in the test suite.
- To change a request's tools, use `ModelRequest.override/2`. The docs used to
  say that assigning `request.tools` changed what the model sees; it changes
  nothing.
- The examples check that they called their tools and print the conversation
  when that check fails. `mix examples.live` runs a script once more after a
  provider's temporary capacity error.
- New `examples/zai_media.exs` sends an image, a PDF and a video to
  GLM-5.3-Flash.

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
