# Compaction Engine

Use `BeamWeaver.Compaction` when your application owns the transcript and
provider calls. It produces a source-linked summary checkpoint and retained
recent events. Your application decides how to render the next request and
atomically activate the candidate. For an agent's built-in conversation,
use [Context Management](context_management.md) instead.


Run this page’s examples in order in one IEx session; later blocks reuse the modules and values defined earlier.

## A first compaction

Complete [Installation](installation.md). This example uses a real OpenAI
summarizer. Repeated background text makes the sample large enough to exercise
compaction with a small demonstration policy.

```elixir
defmodule MyApp.TranscriptCompaction do
  alias BeamWeaver.Compaction.{Canonical, Semantic}
  alias BeamWeaver.Core.{ChatModel, ID, Message}

  def events(lane_id, rows) do
    for {{role, text}, seq} <- Enum.with_index(rows, 1) do
      provenance = %{"origin" => Atom.to_string(role)}

      %{
        event_id: ID.uuidv7(),
        chat_seq: seq,
        lane_event_ordinal: seq,
        run_agent_id: lane_id,
        checkpoint_namespace: "root",
        role: role,
        content: text,
        provenance: provenance,
        provenance_sha256: Canonical.hash(provenance),
        content_hash: Canonical.hash(%{content: text, tool: nil, artifact_ids: [], truncated: false})
      }
    end
  end

  def render(semantic, events) do
    summary = if semantic, do: JSON.encode!(Semantic.to_map(semantic)) <> "\n", else: ""
    {:ok, summary <> Enum.map_join(events, "\n", &"#{&1.role}: #{&1.content}")}
  end

  def summarize(payload) do
    model = BeamWeaver.Models.init_chat_model!("openai:gpt-5.4-mini", max_tokens: 2_048, timeout: 60_000)
    indexed = Enum.with_index(payload.events)
    sources = Map.new(indexed, fn {event, index} -> {index, event.event_id} end)
    input = Enum.map(indexed, fn {event, index} -> %{event_index: index, text: event.content} end)

    schema = %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["facts"],
      "properties" => %{
        "facts" => %{
          "type" => "array",
          "items" => %{
            "type" => "object",
            "additionalProperties" => false,
            "required" => ["event_index", "text"],
            "properties" => %{"event_index" => %{"type" => "integer"}, "text" => %{"type" => "string"}}
          }
        }
      }
    }

    messages = [
      Message.system(
        "Extract at most six distinct order facts. Omit repetitive background. Each fact must cite the supplied event_index containing it."
      ),
      Message.user(JSON.encode!(input))
    ]

    with {:ok, reply} <- ChatModel.invoke(model, messages, response_format: %{name: "facts", schema: schema}) do
      notes =
        for fact <- reply.metadata.parsed["facts"],
            do: %{"text" => fact["text"], "source_event_ids" => [Map.fetch!(sources, fact["event_index"])]}

      earlier = if payload.previous_semantic, do: payload.previous_semantic.critical_context, else: []

      {:ok,
       %{
         "version" => 1,
         "objective" => [],
         "user_requests" => [],
         "constraints" => [],
         "decisions" => [],
         "progress" => %{"completed" => [], "active" => [], "blocked" => [], "pending" => []},
         "critical_context" => earlier ++ notes,
         "errors" => [],
         "artifact_refs" => [],
         "coverage" => payload.covered_range
       }, reply.usage_metadata}
    end
  end
end

alias BeamWeaver.Compaction
alias BeamWeaver.Compaction.{Canonical, Request}
alias BeamWeaver.Core.ID
lane_id = ID.uuidv7()
background = String.duplicate("The customer portal displays the same tracking details and contact instructions. ", 12)
rows = for n <- 1..6, role <- [:user, :assistant], do: {role, "Order A-100#{n} arrives Thursday. " <> background}
events = MyApp.TranscriptCompaction.events(lane_id, rows)
{:ok, rendered} = MyApp.TranscriptCompaction.render(nil, events)

{:ok, request} =
  Request.new(%{
    request_id: ID.uuidv7(),
    trigger: :manual,
    thread_id: "compaction-demo",
    run_id: ID.uuidv7(),
    root_turn_id: ID.uuidv7(),
    run_agent_id: lane_id,
    checkpoint_namespace: "root",
    provider_connection_id: "openai-main",
    destination_identity_hash: Canonical.hash(%{"provider" => "openai", "model" => "gpt-5.4-mini"}),
    model_profile: BeamWeaver.Models.init_chat_model!("openai:gpt-5.4-mini").profile,
    policy: %{recent_tail_min_tokens: 100, recent_tail_max_tokens: 500, minimum_total_reclaim_tokens: 100},
    rendered_request: rendered,
    events: events,
    rehydration_state: %{},
    render: &MyApp.TranscriptCompaction.render/2,
    summarize: &MyApp.TranscriptCompaction.summarize/1
  })

{:ok, result} = Compaction.compact(%{}, request)
:compacted = result.status
true = result.tokens_after < result.tokens_before
true = result.tokens_reclaimed > 0
true = length(result.retained_events) < length(events)
{:ok, next_request} = MyApp.TranscriptCompaction.render(result.compaction_checkpoint.semantic, result.retained_events)
true = next_request =~ "Thursday"
```

The callback asks the model for facts with integer source indices, then maps
those indices to actual event IDs in code. The sample transcript contains
order facts, so the other semantic collections stay empty; a general
conversation summarizer must also preserve requests, constraints and progress.

A returned checkpoint is a **candidate**, not an activated conversation.
This example validates source shape, summary coverage and actual reduction,
but does not persist anything.

## When to use it

The engine starts no processes and owns no database or provider client.
Callbacks perform rendering and summarization. This separates context
transformation from your application's storage, locking and job lifecycle.
Use it when those are already controlled by your application.

## How a compaction runs

The engine measures the rendered request, protects the recent tail and active
inputs, projects oversized old tool results, summarizes the remaining older
events, validates the summary, then renders again to verify useful reduction.
It can return `:pruned` without summarization when projection alone suffices.

Default policy triggers automatic work at 85% of the context limit and targets
70% afterward. It keeps a tail around 10% of the window, bounded by 8,000 and
32,000 tokens, and normally requires at least 8,192 tokens and 15% reduction.
The demonstration above deliberately overrides those large-workload defaults.

## Source events

Each request covers one lane: one `run_agent_id` and checkpoint namespace.
Events carry UUIDv7 IDs, increasing chat positions/ordinals, roles, content,
provenance and canonical content/provenance hashes. Those hashes establish
which source material a summary or projection refers to.

Tool-call/result pairs must remain associated. `artifact_ids` identify durable
copies of large results; `protected: true` or `active_input_event_ids` protects
current input from summarization. Preserve source IDs across retries and
subsequent compactions.

## The request

Supply the exact current `rendered_request`, source events, model context
limits and a renderer that matches your actual next provider request.
Identity fields bind the attempt to a thread, run, root user turn and model
destination. For shared input/output windows, reserve requested output tokens.
Unknown context limits fail instead of being guessed.

`previous_semantic` and `parent_checkpoint_id` connect later attempts to the
active checkpoint. `rehydration_state` carries exact application data alongside
the summary. `focus` can guide summarization without changing source facts.
Context budgeting conservatively counts rendered bytes; it is not the
provider's billing tokenizer.

## The summarizer

The payload includes events, previous semantic state, exact covered range and
an output budget. Return a semantic map or JSON text, optionally with usage.
`Semantic.json_schema/0` describes objectives, user requests, constraints,
decisions, progress, critical context, errors, artifact references and coverage.

Validation checks schema shape, source IDs, exact user excerpts, coverage,
duplicates and size. Invalid output receives a bounded repair attempt.
These checks do not prove every paraphrased fact is correct; evaluate summary
quality against application requirements. Set provider timeouts inside your
callback; the engine does not enforce a provider timeout for you.

## Results

| Status | Meaning |
| --- | --- |
| `:skipped` | Automatic compaction suppressed; no checkpoint |
| `:pruned` | Projection alone reclaimed enough space |
| `:compacted` | A summary plus retained tail reclaimed enough space |

Results include token estimates, retained events, candidate checkpoint,
provider usage and anti-thrashing state. Errors include ineffective reduction,
invalid semantic output, missing artifacts and invalid/oversized requests.
Inspect error details before retrying.

## Save and activate the checkpoint

In one application transaction, save the candidate idempotently and update
the conversation's active checkpoint only if its expected parent/revision
still matches. Use an optimistic revision check or equivalent concurrency
control. A stored candidate alone is not current state.

If another writer advanced the conversation, do not activate the stale
candidate. Reload and construct a new request. If the same candidate is
already active, the original attempt succeeded.

The following in-memory owner demonstrates an atomic revision check and idempotent activation. Its lifetime is the owner process; use a database transaction with the same invariants for durable conversations:

```elixir
defmodule MyApp.CompactionHead do
  def activate(owner, expected_revision, checkpoint, anti_thrash) do
    Agent.get_and_update(owner, fn state ->
      cond do
        state.active_id == checkpoint.checkpoint_id ->
          {{:ok, state.revision}, state}

        state.revision != expected_revision ->
          {{:error, :stale_conversation}, state}

        true ->
          {:ok, recorded} = BeamWeaver.Compaction.State.record_success(anti_thrash, checkpoint)

          updated = %{
            state
            | revision: state.revision + 1,
              active_id: checkpoint.checkpoint_id,
              checkpoints:
                Map.put(
                  state.checkpoints,
                  checkpoint.checkpoint_id,
                  BeamWeaver.Compaction.Checkpoint.to_map(checkpoint)
                ),
              anti_thrash: recorded
          }

          {{:ok, updated.revision}, updated}
      end
    end)
  end
end

{:ok, owner} = Agent.start_link(fn -> %{revision: 0, active_id: nil, checkpoints: %{}, anti_thrash: nil} end)

try do
  {:ok, 1} = MyApp.CompactionHead.activate(owner, 0, result.compaction_checkpoint, result.anti_thrash)
  {:ok, 1} = MyApp.CompactionHead.activate(owner, 0, result.compaction_checkpoint, result.anti_thrash)
  1 = Agent.get(owner, &map_size(&1.checkpoints))
after
  Agent.stop(owner)
end
```

## Compact again later

Render the active semantic checkpoint plus retained events and new events.
Pass the active checkpoint as parent and carry its semantic state forward.
Keep sequence numbers increasing; do not reassign event IDs or turn old
summary text into fabricated source events.

Append new events with increasing sequence numbers and use the prior checkpoint as the parent. This performs a second real summary:

```elixir
checkpoint = result.compaction_checkpoint
last_seq = Enum.max_by(events, & &1.chat_seq).chat_seq
new_rows = for n <- 7..12, role <- [:user, :assistant], do: {role, "Order B-#{n} arrives Friday. " <> background}

new_events =
  MyApp.TranscriptCompaction.events(lane_id, new_rows)
  |> Enum.map(fn event ->
    %{event | chat_seq: event.chat_seq + last_seq, lane_event_ordinal: event.lane_event_ordinal + last_seq}
  end)

lane = result.retained_events ++ new_events
{:ok, rendered} = MyApp.TranscriptCompaction.render(checkpoint.semantic, lane)

next = %{
  request
  | request_id: ID.uuidv7(),
    parent_checkpoint_id: checkpoint.checkpoint_id,
    previous_semantic: checkpoint.semantic,
    events: lane,
    rendered_request: rendered
}

{:ok, second} = Compaction.compact(%{}, next)
:compacted = second.status
true = second.compaction_checkpoint.parent_checkpoint_id == checkpoint.checkpoint_id
```

## Automatic compaction

Keep `Compaction.State` per conversation lane. Pass it as `anti_thrash`, record
success only after activation, and observe new tokens as context grows.
The returned state or an ineffective-compaction error's state governs the
next attempt. Suppression includes insufficient growth, a low request size,
per-turn limits, rapid refill and pending cancellation. A new root turn resets
the per-turn allowance; it does not erase the active summary.

After activating a successful candidate, retain the anti-thrashing state. An unchanged small lane needs no immediate automatic summary:

```elixir
{:ok, anti_thrash} = BeamWeaver.Compaction.State.record_success(second.anti_thrash, second.compaction_checkpoint)
{:ok, skipped} = Compaction.compact(%{}, %{next | request_id: ID.uuidv7(), trigger: :auto, anti_thrash: anti_thrash})
:skipped = skipped.status
IO.inspect(skipped.provider_usage, label: "Automatic compaction suppression")
```

## Large tool results

Old tool results larger than the projection threshold retain excerpts instead
of full content. Their full contents must already have durable artifact IDs;
otherwise compaction fails. The checkpoint's projection manifest plus
`ToolProjection.replay/2` reconstructs the same projection from originals
and verifies source identity.

## Recovery

Allocate a request ID once and reuse it for the same attempt. Reconcile
ambiguous provider completion or transaction outcomes before making another
summary request. Keep source events and candidate checkpoints until activation
or abandonment is resolved. Compaction does not supply a scheduler.

## Limits

Requests allow 10,000 events, up to 1 MiB per event, 128 artifact IDs per event,
1 MiB of rehydration state, 128 KiB of semantic output and 2,000 bytes of focus.
Summarization is bounded to three chunks plus one repair. Portable compaction
is the supported mode; provider-native context mechanisms are separate.
