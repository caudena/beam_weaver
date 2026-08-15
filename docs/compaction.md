# Application-Owned Compaction

`BeamWeaver.Compaction` is a pure, provider-neutral engine for applications
that already own durable conversation history. It does not replace the
`compact_conversation` tool or summarization middleware, and it does not own a
database, process, scheduler, provider connection, or activation pointer.

## Responsibilities

The application supplies a validated `BeamWeaver.Compaction.Request` with:

- one ordered conversation lane;
- the exact rendered provider request and model profile;
- an optional previous `Semantic` checkpoint;
- application-owned rehydration state;
- a rendering callback and one model-summary callback.

The engine applies the reusable mechanics: context budgeting, safe recent-tail
selection, deterministic large-tool projection, bounded hierarchical
summarization, one schema repair, source-backed semantic validation,
effectiveness checks, and anti-thrash state. It returns a `Result`; it never
persists or activates it.

```elixir
with {:ok, request} <- BeamWeaver.Compaction.Request.new(attrs),
     {:ok, result} <- BeamWeaver.Compaction.compact(%{}, request),
     :ok <- MyApp.Conversations.commit(result.compaction_checkpoint) do
  {:ok, result}
end
```

Commit the semantic checkpoint, any executable checkpoint, and the lane's
active-head update in the application's own transaction. On restart, reconcile
those records using the same application authority; do not infer activation
from a successful model response alone.

## Budgeting and suppression

`BeamWeaver.ContextBudget.new/3` calculates an effective input limit from the
profile's declared separate-input or shared input/output semantics. Unknown
limits fail closed. Optional category byte counts are converted with the same
counter so the application can explain the total without maintaining a second
estimate.

Persist `BeamWeaver.Compaction.State` per conversation lane when automatic or
overflow compaction is enabled. `observe_new_tokens/2`, `auto_suppression/2`,
and `record_success/4` provide bounded circuit evidence; the application decides
when to invoke them and commits the resulting state with its active head.

## Provider boundary

The summary callback is the only model boundary. Give it a no-tools request and
return either `{:ok, semantic}` or `{:ok, semantic, usage}`. Provider errors are
preserved as typed BeamWeaver errors. The engine permits portable compaction;
`:native` currently returns `:native_compaction_unsupported` rather than
guessing an opaque provider contract.
