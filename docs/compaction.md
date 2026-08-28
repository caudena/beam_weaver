# Application-Owned Compaction

`BeamWeaver.Compaction` is a pure, provider-neutral engine for applications
that already own durable conversation history. It selects a safe recent tail,
projects large tool results, optionally summarizes older history, validates the
summary against its source events, and returns an immutable checkpoint.

It does **not** own a database, process, scheduler, provider connection,
idempotency record, or active-context pointer. The application remains
responsible for loading one ordered conversation lane, executing the summary
model callback, persisting the result, atomically activating it, and recovering
interrupted attempts.

This API is separate from the model-invoked `compact_conversation` tool and the
summarization middleware. Use it when the application—not a model or a
BeamWeaver agent—decides when a durable conversation should be compacted.

## Execution model

One call has three boundaries:

1. **Application preparation.** Load one bounded lane, freeze the provider
   connection and destination, render the exact request that would otherwise
   be sent, and construct a `BeamWeaver.Compaction.Request`.
2. **Pure compaction.** Call `BeamWeaver.Compaction.compact/2`. BeamWeaver may
   invoke the supplied `render` and `summarize` functions, but it starts no
   process and writes no application state.
3. **Application commit.** If the result is `:pruned` or `:compacted`, persist
   and activate the returned checkpoint in an application transaction guarded
   by the expected parent and active-head generation.

The first argument to `compact/2` is the existing BeamWeaver agent-state slot.
The application-owned engine does not currently read or mutate it, so callers
that do not have agent state pass `%{}`.

## Building source events

Every source value is a closed `BeamWeaver.Compaction.InputEvent`. Events must
belong to one `run_agent_id` and `checkpoint_namespace`, have increasing lane
ordinals, and have unique IDs. The request accepts at most 10,000 events.

`provenance_sha256` and `content_hash` protect different data:

- `provenance_sha256` hashes the event's provenance map;
- `content_hash` hashes exactly `content`, `tool`, `artifact_ids`, and
  `truncated`.

Use `BeamWeaver.Compaction.Canonical.hash/1` for both. Do not hash an Elixir
term serialization or ordinary JSON whose map ordering can change.

```elixir
alias BeamWeaver.Compaction.{Canonical, InputEvent}
alias BeamWeaver.Core.ID

run_agent_id = ID.uuidv7()
provenance = %{"origin" => "direct_user"}

content = "Keep the deployment reversible."
tool = nil
artifact_ids = []
truncated = false

{:ok, event} =
  InputEvent.new(%{
    event_id: ID.uuidv7(),
    chat_seq: 42,
    run_agent_id: run_agent_id,
    checkpoint_namespace: "root",
    lane_event_ordinal: 7,
    role: :user,
    provenance: provenance,
    provenance_sha256: Canonical.hash(provenance),
    content: content,
    tool: tool,
    artifact_ids: artifact_ids,
    truncated: truncated,
    content_hash:
      Canonical.hash(%{
        content: content,
        tool: tool,
        artifact_ids: artifact_ids,
        truncated: truncated
      }),
    token_count: byte_size(content),
    protected: true
  })
```

`token_count` is optional. When omitted, the engine conservatively uses the
canonical event byte size while selecting summary chunks. Mark current user
input and any other event that cannot move into the summarized prefix as
`protected: true`, and also include current input IDs in
`active_input_event_ids`.

Large tool output may be replaced by a deterministic projection. A projected
tool event must reference at least one durable artifact containing the original
result; otherwise compaction fails with `:missing_compaction_artifact`.

## Building a request

The model profile must declare how its context limit works:

- `:separate_input` uses `max_input_tokens - provider_reserved_tokens`;
- `:shared_input_output` uses
  `max_context_tokens - provider_reserved_tokens - requested_max_output_tokens`;
- missing or unknown limit semantics fail closed.

`render` receives the semantic checkpoint, if any, plus the retained source
events. It must return the exact binary request representation whose size is
being tested. `summarize` receives a closed map prepared by BeamWeaver and must
return either `{:ok, semantic}` or `{:ok, semantic, usage}`. It may also return
the semantic value as a JSON binary.

```elixir
alias BeamWeaver.Compaction
alias BeamWeaver.Compaction.{
  Canonical,
  InputEvent,
  Policy,
  RehydrationState,
  Request,
  Semantic
}

alias BeamWeaver.Core.ID
alias BeamWeaver.Models.Profile

events = [event]

{:ok, policy} = Policy.new(%{mode: :portable})

{:ok, rehydration_state} =
  RehydrationState.new(%{
    "todo_revision" => 8,
    "workspace_revision" => "workspace-17"
  })

render = fn semantic, retained_events ->
  Canonical.encode(%{
    semantic: semantic && Semantic.to_map(semantic),
    events: Enum.map(retained_events, &InputEvent.to_map/1)
  })
end

{:ok, rendered_provider_request} = render.(nil, events)

summarize = fn payload ->
  # The application owns provider admission, timeout, cancellation, and usage.
  MyApp.CompactionModel.summarize(payload,
    tools: [],
    timeout: policy.provider_timeout_ms
  )
end

{:ok, request} =
  Request.new(%{
    request_id: ID.uuidv7(),
    parent_checkpoint_id: nil,
    trigger: :manual,
    thread_id: ID.uuidv7(),
    run_id: ID.uuidv7(),
    root_turn_id: ID.uuidv7(),
    run_agent_id: run_agent_id,
    checkpoint_namespace: "root",
    provider_connection_id: ID.uuidv7(),
    destination_identity_hash: String.duplicate("a", 64),
    model_profile: %Profile{
      context_limit_kind: :separate_input,
      max_input_tokens: 128_000,
      max_output_tokens: 8_192
    },
    rendered_request: rendered_provider_request,
    requested_max_output_tokens: 8_192,
    events: events,
    active_input_event_ids: [event.event_id],
    previous_semantic: nil,
    rehydration_state: rehydration_state,
    policy: policy,
    render: render,
    summarize: summarize
  })

{:ok, result} = Compaction.compact(%{}, request)
```

`request_id` becomes the returned checkpoint ID. Allocate it once and reuse it
for an idempotent application attempt. On later compactions, set
`parent_checkpoint_id` and `previous_semantic` from the currently active
checkpoint; never silently switch to a newer parent during execution.

The engine carries `deadline_at` and `Policy.provider_timeout_ms` as application
policy data. Because callbacks may use any provider client, the application
callback must enforce the actual deadline, timeout, cancellation, and
no-tools request.

### Accounting identity and strict lane input

`Request.accounting` can bind a provider usage floor to the exact request it
measured:

```elixir
accounting: %{
  method: :local_tokenizer_v1,
  profile_hash: model_profile_hash,
  reported_input_tokens: 91_204,
  category_bytes: %{system: 4_100, history: 81_000, current_input: 6_104}
}
```

`reported_input_tokens` is a lower bound, never a replacement for local
accounting. BeamWeaver takes the greater of the compatible provider report and
the local estimate. Persist the accounting method, version, and profile hash
with the lane state; when that identity changes,
`BeamWeaver.Compaction.State.rebase_accounting/2` clears only unit-dependent
anti-thrash evidence rather than comparing counts from different token units.
Do not carry a usage report from an earlier request, model profile, or rendered
body into a new compaction request.

For `:shared_input_output` profiles, `requested_max_output_tokens` is validated
and subtracted together with provider-reserved tokens before the input budget is
calculated. A missing, negative, or impossible reservation fails closed instead
of creating a negative or inflated input limit.

The source events must form one strictly ordered lane. Event IDs and
`lane_event_ordinal` values must both be unique; duplicate ordinals are rejected
even if chat sequence values differ. Optional `focus` text must be valid UTF-8
and at most 2,000 bytes.

When deterministic tool projection is persisted, recovery can verify it with
`BeamWeaver.Compaction.ToolProjection.replay/2`. Replay checks every manifest
entry against the source event and artifact evidence and returns the projected
event list only when the complete manifest verifies.

## Summary output contract

Portable compaction expects a closed semantic object with these top-level
fields:

```elixir
%{
  "version" => 1,
  "objective" => [],
  "user_requests" => [],
  "constraints" => [],
  "decisions" => [],
  "progress" => %{
    "completed" => [],
    "active" => [],
    "blocked" => [],
    "pending" => []
  },
  "critical_context" => [],
  "errors" => [],
  "artifact_refs" => [],
  "coverage" => %{
    "first_chat_seq" => payload.covered_range.first_chat_seq,
    "last_chat_seq" => payload.covered_range.last_chat_seq
  }
}
```

Semantic entries cite source event IDs. User requests must contain an exact
excerpt from the cited direct-user event, or a typed secret-omission record.
Coverage must exactly match the chunk supplied to the summarizer. Unknown
fields, unknown source IDs, duplicate entries, invalid excerpts, oversized
collections, and output over `policy.semantic_max_bytes` fail validation.

When validation fails, portable mode may make at most
`policy.maximum_schema_repairs` additional calls. A repair call receives the
same payload plus `repair.invalid_output` and a typed validation error. The
source events and a previously accepted semantic checkpoint are never mutated.

## Result states

`BeamWeaver.Compaction.compact/2` returns `{:ok, result}` for three non-error
states:

| Status | Meaning | Model callback | Checkpoint |
| --- | --- | --- | --- |
| `:skipped` | An automatic attempt was suppressed or was below the trigger. | Not called | `nil` |
| `:pruned` | Deterministic tool projection reclaimed enough context without semantic summarization. | Not called | Present |
| `:compacted` | Older history was summarized and the final request met the effectiveness policy. | Called one or more times | Present |

Errors are returned as `{:error, %BeamWeaver.Core.Error{}}`. Rendering and
summary callback exceptions are converted into typed errors. An ineffective
summary is an error rather than a checkpoint that the application could
accidentally activate.

The returned `retained_events` are the source events to render alongside the
semantic checkpoint. `artifact_ids` identifies source artifacts that remain
referenced. `provider_usage` is callback-supplied usage; BeamWeaver does not
price or persist it here.

## Persistence and activation

`BeamWeaver.Compaction.Checkpoint.to_map/1` produces the
application-facing checkpoint payload. Persist the checkpoint and move the
lane's active head only after all application preconditions still match.

The transaction normally needs to:

1. insert-or-verify the immutable checkpoint under `checkpoint_id`;
2. verify its `parent_checkpoint_id` is still the active checkpoint;
3. compare-and-swap the lane generation or active-head hash;
4. persist the exact retained-event projection and rehydration-state hash;
5. update `BeamWeaver.Compaction.State` only for the checkpoint that became
   active;
6. append the application's activation event or outbox record.

Do not interpret a successful summary model response, a returned `%Result{}`,
or a stored checkpoint row as activation. Only the application's successful
head transaction makes a checkpoint current.

```elixir
case BeamWeaver.Compaction.compact(%{}, request) do
  {:ok, %{status: :skipped} = result} ->
    {:ok, result}

  {:ok, %{status: status, compaction_checkpoint: checkpoint} = result}
  when status in [:pruned, :compacted] ->
    MyApp.Repo.transaction(fn ->
      MyApp.Compaction.insert_or_verify!(
        BeamWeaver.Compaction.Checkpoint.to_map(checkpoint)
      )

      MyApp.Compaction.activate_if_current!(
        checkpoint.parent_checkpoint_id,
        checkpoint.checkpoint_id,
        checkpoint.retained_event_ids
      )
    end)

    {:ok, result}

  {:error, %BeamWeaver.Core.Error{} = error} ->
    {:error, error}
end
```

The functions under `MyApp.Compaction` are intentionally application-specific.
BeamWeaver does not provide a hidden repository or assume an Ecto schema.

## Automatic compaction state

Persist one `BeamWeaver.Compaction.State` per conversation lane if automatic or
overflow compaction is enabled.

- `State.observe_new_tokens/2` records the current amount of new context since
  the active checkpoint.
- `State.auto_suppression/2` explains whether an automatic attempt must be
  skipped.
- `State.record_success/4` advances successful automatic/overflow evidence
  after activation.

Store the state with the active head. Do not call `record_success/4` merely
because the engine returned a candidate checkpoint; a failed activation must
not consume the lane's automatic-compaction allowance.

## Recovery and idempotency

Recovery belongs to the application because it owns both provider attempts and
the active-head transaction.

- If no summary request was written, the application may fail the attempt.
- If provider write or completion is uncertain, preserve that uncertainty;
  do not blindly issue a second summary request.
- If a validated checkpoint was stored but not activated, compare its exact
  parent and head fence before activation.
- If the head already points at the same checkpoint and hashes match, return
  the existing success.
- If the active parent changed, leave the candidate immutable and report a
  stale-head conflict rather than rebasing it.

Persist enough application evidence to distinguish those cases. The pure
engine cannot reconstruct network or database truth after a crash.

## Limits and failure behavior

The public values are bounded and fail closed:

- at most 10,000 input events per request;
- event content at most 1 MiB and at most 128 artifact IDs per event;
- rehydration state at most 1 MiB of canonical JSON;
- semantic output defaults to 128 KiB;
- hierarchy, repair, and retry counts are bounded by `Policy`;
- provider-native mode currently returns `:native_compaction_unsupported`.

`BeamWeaver.ContextBudget` uses conservative UTF-8 byte accounting for the
final rendered provider request. It does not claim tokenizer-exact accounting.
Applications may expose category estimates for explanation, but the rendered
request remains the final budget authority.
