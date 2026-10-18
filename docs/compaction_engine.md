# Compaction Engine

`BeamWeaver.Compaction` shortens a conversation that your application stores
itself: it keeps the newest turns word for word, has your summarizer condense
the older ones, checks the summary against its sources, and returns a
checkpoint for you to save. Use it when transcripts live in your own tables;
for an agent's own thread, use [Context Management](context_management.md)
instead.

## A first compaction

Your application turns its stored rows into source events, and gives the
engine two functions: `render/2`, which builds the exact request your
application would send the model, and `summarize/1`, which calls a model. Here
a plain function stands in for the model, so the example runs without one:

```elixir
defmodule MyApp.Transcript do
  alias BeamWeaver.Compaction.Canonical
  alias BeamWeaver.Core.ID

  # Turns stored chat rows into the source events of one conversation lane.
  def events(lane_id, rows, first_seq \\ 1) do
    for {{role, text}, seq} <- Enum.with_index(rows, first_seq) do
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

  # The exact text sent to the model: the summary so far, then the kept turns.
  def render(semantic, events) do
    summary = if semantic, do: "Summary: " <> Enum.map_join(semantic.critical_context, " ", & &1["text"]) <> "\n", else: ""
    {:ok, summary <> Enum.map_join(events, "", &"#{&1.role}: #{&1.content}\n")}
  end

  # Stands in for a summary model: keeps the first sentence of every turn.
  def summarize(payload) do
    earlier = if payload.previous_semantic, do: payload.previous_semantic.critical_context, else: []
    notes = for event <- payload.events, do: %{"text" => first_sentence(event.content), "source_event_ids" => [event.event_id]}

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
       "coverage" => %{
         "first_chat_seq" => payload.covered_range.first_chat_seq,
         "last_chat_seq" => payload.covered_range.last_chat_seq
       }
     }}
  end

  defp first_sentence(text), do: text |> String.split(~r/(?<=[.?!])\s/, parts: 2) |> hd()
end
```

Then build a request for one conversation and compact it:

```elixir
alias BeamWeaver.Compaction
alias BeamWeaver.Compaction.{Request, State}
alias BeamWeaver.Core.ID

rows = [
  {:user, "Where is order A-1001? I ordered it last week."},
  {:assistant, "Order A-1001 arrives on Thursday. It left our warehouse on Monday, and the courier delivers between 9:00 and 17:00."},
  {:user, "Can I still change the delivery address? I'll be at work that day."},
  {:assistant, "Yes, until Wednesday at noon. Use the link in your shipping email, or I can change it for you now."},
  {:user, "Please send it to my office: Rua Augusta 12, Lisbon."},
  {:assistant, "Done, order A-1001 now goes to Rua Augusta 12, Lisbon. A confirmation email with the new address is on its way."},
  {:user, "When does order A-1002 ship? Thanks for your help!"},
  {:assistant, "Order A-1002 ships on Friday. It comes from our Porto warehouse, so it should reach you on Monday."}
]

lane_id = ID.uuidv7()
events = MyApp.Transcript.events(lane_id, rows)
{:ok, rendered} = MyApp.Transcript.render(nil, events)

{:ok, request} =
  Request.new(%{
    request_id: ID.uuidv7(),
    trigger: :manual,
    thread_id: "ticket-42",
    run_id: ID.uuidv7(),
    root_turn_id: ID.uuidv7(),
    run_agent_id: lane_id,
    checkpoint_namespace: "root",
    provider_connection_id: "openai-main",
    destination_identity_hash: BeamWeaver.Compaction.Canonical.hash(%{"provider" => "openai", "model" => "gpt-5.4-mini"}),
    # A small window and small limits, so that a short chat compacts.
    model_profile: %{context_limit_kind: :separate_input, max_input_tokens: 16_000, max_output_tokens: 1_000},
    policy: %{recent_tail_min_tokens: 100, recent_tail_max_tokens: 300, minimum_total_reclaim_tokens: 100},
    rendered_request: rendered,
    events: events,
    rehydration_state: %{},
    render: &MyApp.Transcript.render/2,
    summarize: &MyApp.Transcript.summarize/1
  })

{:ok, result} = Compaction.compact(%{}, request)
{:ok, context} = MyApp.Transcript.render(result.compaction_checkpoint.semantic, result.retained_events)

{result.status, context}
#=> {:compacted,
#    "Summary: Where is order A-1001? Order A-1001 arrives on Thursday. Can I still change the delivery address? Yes, until Wednesday at noon.\nuser: Please send it to my office: Rua Augusta 12, Lisbon.\n" <> _}
```

The engine kept the last two user turns and the answers after them, summarized
the four turns before, and rendered the result to check that it is smaller.
It didn't save anything: the checkpoint in `result` is a candidate until your
application stores it and switches the conversation to it.

## When to use it

Agents keep their thread in checkpointed state, and the summarization
middleware or `compact_conversation` shorten it for you. The Compaction
Engine is for the other case: your application stores the transcript, for
example as rows of a chat app, calls the model itself, and decides when to
compact. The engine is a plain function. It starts no process, stores nothing
and calls no provider: everything that touches a model or a database happens
in your callbacks and your transaction.

## How a compaction runs

`BeamWeaver.Compaction.compact/2` takes `%{}` and a request, and then:

1. Measures the rendered request against the model's context window.
2. Picks a recent tail to keep word for word: roughly `recent_tail_ratio` of
   the window, always including the last two user turns, protected events,
   and both halves of a tool call.
3. Shrinks large tool results in the older part to an excerpt. If that alone
   frees enough room, it stops with `:pruned`.
4. Calls `summarize` for the older part, in up to three chunks, each with the
   summary so far.
5. Validates each summary, and asks the summarizer once more if one is
   invalid (one repair per compaction).
6. Renders the summary and the tail, and checks that the result is small
   enough: at most 70% of the window, and at least 15% and
   `minimum_total_reclaim_tokens` smaller than before.

The policy holds these numbers; its defaults suit real context windows:

| Policy option | Meaning | Default |
| --- | --- | --- |
| `trigger_ratio` | Share of the window at which `:auto` compaction starts | `0.85` |
| `recent_tail_ratio`, `recent_tail_min_tokens`, `recent_tail_max_tokens` | Size of the kept tail | `0.10`, `8_000`, `32_000` |
| `post_compaction_target_ratio` | Largest share of the window the result may use | `0.70` |
| `minimum_total_reclaim_tokens`, `minimum_total_reclaim_ratio` | Least a compaction must save | `8_192`, `0.15` |
| `maximum_schema_repairs` | Extra summarizer calls after an invalid summary | `1` |
| `maximum_auto_compactions_per_root_turn` | Automatic compactions per user turn; a new `root_turn_id` starts the count again | `3` |

## Source events

Each event is one message of the conversation, all from one lane: one
`run_agent_id` and `checkpoint_namespace`, the same as the request's. A
request takes up to 10,000 events.

| Field | Meaning |
| --- | --- |
| `event_id` | A UUIDv7, such as `BeamWeaver.Core.ID.uuidv7/0` makes; summaries cite it |
| `chat_seq`, `lane_event_ordinal` | Positions from 1; ordinals must strictly increase |
| `role` | `:user`, `:assistant` or `:tool` |
| `content` | The text, up to 1 MiB |
| `tool` | For a tool result, a map with its `call_id`; an assistant event lists its calls under `calls`. A call and its result stay together. |
| `artifact_ids` | Ids of durable copies of the content, up to 128 |
| `provenance`, `provenance_sha256` | Where the event came from, and its hash |
| `content_hash` | Hash of `content`, `tool`, `artifact_ids` and `truncated` |
| `token_count` | Optional size; otherwise the size of the event as JSON |
| `protected` | `true` keeps the event, and everything after it, word for word |

`BeamWeaver.Compaction.Canonical.hash/1` makes both hashes from canonical
JSON, so they don't depend on map order. Mark the current user input with
`protected: true` or list it in the request's `active_input_event_ids`.

## The request

| Field | Meaning |
| --- | --- |
| `request_id` | Becomes the checkpoint id; reuse it when you retry the same attempt |
| `trigger` | `:manual`, `:auto`, `:overflow` or `:model_switch_preflight` |
| `thread_id`, `run_id`, `root_turn_id` | Your ids for the conversation, the run and the user's turn |
| `provider_connection_id`, `destination_identity_hash` | The connection and the model destination this context is for; the hash is 64 hex characters |
| `model_profile` | The window: `context_limit_kind: :separate_input` with `max_input_tokens`, or `:shared_input_output` with `max_context_tokens` |
| `requested_max_output_tokens` | With a shared window, the output tokens to keep free (default 0) |
| `rendered_request` | The request you would send now, as `render/2` builds it |
| `events`, `active_input_event_ids` | The lane's events in order, and the current input |
| `parent_checkpoint_id`, `previous_semantic` | The active checkpoint and its summary, on later compactions |
| `rehydration_state` | Exact data to keep beside the summary, such as a to-do list revision |
| `policy`, `anti_thrash`, `focus` | Policy options, the lane's state for automatic compaction, and a hint for the summary |

A real model's profile has these limits: use `model.profile` from
`BeamWeaver.Models.init_chat_model!/2`, or
`BeamWeaver.Models.ProfileRegistry.fetch/2`. A profile without them fails
with `:unknown_context_limit` rather than guess. Sizes are counted
conservatively as one token per byte of the rendered request.

## The summarizer

`summarize/1` receives a map with the `events` to summarize (with string
roles), the `previous_semantic` summary or `nil`, the `covered_range` the
summary must state as its `coverage`, a `maximum_output_tokens` budget, and an
optional `focus`. It returns `{:ok, summary}` or `{:ok, summary, usage}`, where
the summary is a map or a JSON string.

The summary has a closed shape, and `BeamWeaver.Compaction.Semantic.json_schema/0`
returns it as JSON Schema: `objective`, `user_requests`, `constraints`,
`decisions`, `progress` (`completed`, `active`, `blocked`, `pending`),
`critical_context`, `errors`, `artifact_refs`, `coverage` and `version: 1`.
The engine rejects a summary that:

- cites an event id that is neither in `events` nor in the previous summary,
- quotes a user request that isn't word for word in the cited user message,
- states a `coverage` other than `covered_range`,
- has unknown fields, duplicate entries, or more than 128 KiB.

When a summary is rejected, the summarizer gets one more call with
`repair: %{invalid_output: ..., error: ...}` in the payload. Copy the entries
of `previous_semantic` that still matter into the new summary, since it
replaces the old one. `user_requests` are the exception: each must quote a
user message in the current `events`. A summarizer that calls a model:

```elixir
defmodule MyApp.CompactionModel do
  alias BeamWeaver.Compaction.Semantic
  alias BeamWeaver.Core.{ChatModel, Message}

  @instructions """
  Summarize the conversation events as JSON that matches this schema. Cite
  event ids in source_event_ids, and quote user requests exactly.
  """

  def summarize(payload) do
    model = BeamWeaver.Models.init_chat_model!("openai:gpt-5.4-mini")
    schema = JSON.encode!(Semantic.json_schema())
    messages = [Message.system(@instructions <> schema), Message.user(JSON.encode!(payload))]

    with {:ok, reply} <- ChatModel.invoke(model, messages) do
      {:ok, Message.text(reply), reply.usage_metadata}
    end
  end
end
```

The engine doesn't enforce the policy's `provider_timeout_ms`: set timeouts
on the model call yourself. Exceptions in `render/2` and `summarize/1` come
back as errors.

## Results

`compact/2` returns `{:ok, result}` with one of three statuses:

| Status | Meaning | Summarizer called | Checkpoint |
| --- | --- | --- | --- |
| `:skipped` | An `:auto` attempt that wasn't needed; the reason is in `provider_usage.suppression` | No | `nil` |
| `:pruned` | Shrinking large tool results freed enough room | No | Yes |
| `:compacted` | The older turns were summarized | Yes | Yes |

The result also has the `retained_events` to send after the summary,
`tokens_before`, `tokens_after` and `tokens_reclaimed`, the summarizer's
usage, and the lane's state for automatic compaction as `anti_thrash` (see
[Automatic compaction](#automatic-compaction)). Everything else is
`{:error, %BeamWeaver.Core.Error{}}`; the common types are
`:ineffective_compaction` (the result wasn't small enough; save the state in
its `details.anti_thrash`, see [Automatic compaction](#automatic-compaction)),
`:invalid_compaction_semantic` (the summary failed validation twice),
`:compaction_provider_error` (the summarizer raised or returned something
other than a summary or a `BeamWeaver.Core.Error`, which comes back as it is),
`:missing_compaction_artifact`, `:compaction_input_too_large` and
`:invalid_compaction_request`.

## Save and activate the checkpoint

`BeamWeaver.Compaction.Checkpoint.to_map/1` turns the checkpoint into a map
that you can store as JSON. Save it and point the conversation at it in one
transaction, and only if nobody moved the conversation since you built the
request. Here a `generation` column serves as that fence:

```elixir
defmodule MyApp.Repo do
  use Ecto.Repo, otp_app: :my_app, adapter: Ecto.Adapters.Postgres
end

defmodule MyApp.Conversations do
  import Ecto.Query

  alias BeamWeaver.Compaction.{Checkpoint, State}

  def activate(conversation_id, generation, %Checkpoint{} = checkpoint, %State{} = state) do
    {:ok, state} = State.record_success(state, checkpoint)

    MyApp.Repo.transact(fn ->
      MyApp.Repo.insert_all("compaction_checkpoints", [%{id: checkpoint.checkpoint_id, data: Checkpoint.to_map(checkpoint)}],
        on_conflict: :nothing
      )

      moved =
        from(c in "conversations", where: c.id == ^conversation_id and c.generation == ^generation)
        |> MyApp.Repo.update_all(
          set: [active_checkpoint_id: checkpoint.checkpoint_id, compaction_state: Map.from_struct(state), generation: generation + 1]
        )

      case moved do
        {1, _} -> {:ok, checkpoint.checkpoint_id}
        {0, _} -> {:error, :stale_conversation}
      end
    end)
  end
end
```

A returned result, a summary, or a saved row doesn't make a checkpoint
current; only your transaction does. If it fails with a stale conversation,
leave the candidate as it is and build a new request from the new state.

## Compact again later

The conversation now continues from the summary and the retained turns. For
the next compaction, send those turns with the new ones, and pass the active
checkpoint as the parent:

```elixir
checkpoint = result.compaction_checkpoint

more = [
  {:user, "Could you add gift wrap to order A-1002? It's a birthday present."},
  {:assistant, "Gift wrap is added to order A-1002 at no extra cost. It still ships on Friday."},
  {:user, "Great. What is your return window?"},
  {:assistant, "You can return items within 30 days of delivery."}
]

lane = result.retained_events ++ MyApp.Transcript.events(lane_id, more, 9)
{:ok, rendered} = MyApp.Transcript.render(checkpoint.semantic, lane)

next = %{
  request
  | request_id: ID.uuidv7(),
    parent_checkpoint_id: checkpoint.checkpoint_id,
    previous_semantic: checkpoint.semantic,
    events: lane,
    rendered_request: rendered
}

{:ok, second} = Compaction.compact(%{}, next)
{second.status, second.compaction_checkpoint.parent_checkpoint_id == checkpoint.checkpoint_id}
#=> {:compacted, true}
```

The new summary carries the old one forward and covers the turns that were
kept last time. Keep `chat_seq` and the ordinals growing across compactions.

## Automatic compaction

With `trigger: :auto`, the engine first checks whether compaction is due: it
skips without calling the summarizer while the request is below
`trigger_ratio` of the window, or when the lane's
`BeamWeaver.Compaction.State` says it compacted too recently. Keep one state
per conversation and pass it as `anti_thrash`. Every result returns it as
`result.anti_thrash`; record the activated checkpoint on it with
`State.record_success/2` and save it with the checkpoint (`activate/4` above
does):

```elixir
{:ok, state} = State.record_success(second.anti_thrash, second.compaction_checkpoint)

{:ok, skipped} = Compaction.compact(%{}, %{next | trigger: :auto, request_id: ID.uuidv7(), anti_thrash: state})
{skipped.status, skipped.provider_usage}
#=> {:skipped, %{suppression: :insufficient_new_tokens}}
```

Update the state with `State.observe_new_tokens/2` as the conversation grows.
The other reasons to skip are `:below_trigger`, `:automatic_limit`,
`:rapid_refill` and `:cancellation_pending`. `:rapid_refill` follows an
attempt that failed with `:ineffective_compaction`: save the error's
`details.anti_thrash` as the lane's state, and automatic compaction waits
until `State.observe_new_tokens/2` reports new context. `:automatic_limit`
counts the automatic compactions of one user turn: a request with a new
`root_turn_id` starts again at zero. Record a success only after your transaction activated
the checkpoint, so a failed activation doesn't count. A state loaded from
JSON goes back through `State.new/1`.

## Large tool results

A tool result over 2 KiB in the summarized part is replaced by its first and
last KiB: the event's `content` becomes `nil`, and `tool.result_excerpt` holds
the excerpt. The full result must already be stored somewhere durable, listed
in the event's `artifact_ids`; otherwise compaction fails with
`:missing_compaction_artifact`. The checkpoint's `projection_manifest` records
each replacement, and `BeamWeaver.Compaction.ToolProjection.replay/2` rebuilds
the shortened events from the originals and checks every hash, for example
when you rebuild a conversation after a restart.

## Recovery

The engine can't know what happened to a provider call or a transaction after
a crash, so your application keeps enough records to tell:

- Allocate `request_id` once per attempt and reuse it on retry; it is the
  checkpoint id, so saving is idempotent.
- If you don't know whether the summary call completed, don't send a second
  one blindly; check your records first.
- If a checkpoint was saved but not activated, activate it only if its parent
  is still the active checkpoint.
- If the conversation already points at the same checkpoint, the attempt
  succeeded; return that.
- If the active checkpoint changed, keep the candidate unused and start over.

## Limits

- 10,000 events per request; 1 MiB of content and 128 artifact ids per event.
- 1 MiB of `rehydration_state` as canonical JSON; 128 KiB per summary.
- A `focus` of up to 2,000 bytes.
- At most three summarizer calls per compaction, plus one repair.
- Only the `:portable` mode exists; `mode: :native` fails with
  `:native_compaction_unsupported`.

## Reference

- [`BeamWeaver.Compaction`](https://hexdocs.pm/beam_weaver/BeamWeaver.Compaction.html): `compact/2`
- [`BeamWeaver.Compaction.Request`](https://hexdocs.pm/beam_weaver/BeamWeaver.Compaction.Request.html): the request and its callbacks
- [`BeamWeaver.Compaction.InputEvent`](https://hexdocs.pm/beam_weaver/BeamWeaver.Compaction.InputEvent.html): one source event
- [`BeamWeaver.Compaction.Policy`](https://hexdocs.pm/beam_weaver/BeamWeaver.Compaction.Policy.html): thresholds and limits
- [`BeamWeaver.Compaction.Semantic`](https://hexdocs.pm/beam_weaver/BeamWeaver.Compaction.Semantic.html): the summary shape and its JSON Schema
- [`BeamWeaver.Compaction.Result`](https://hexdocs.pm/beam_weaver/BeamWeaver.Compaction.Result.html): what `compact/2` returns
- [`BeamWeaver.Compaction.Checkpoint`](https://hexdocs.pm/beam_weaver/BeamWeaver.Compaction.Checkpoint.html): the checkpoint to save and activate
- [`BeamWeaver.Compaction.State`](https://hexdocs.pm/beam_weaver/BeamWeaver.Compaction.State.html): per-conversation state for automatic compaction
- [`BeamWeaver.Compaction.Canonical`](https://hexdocs.pm/beam_weaver/BeamWeaver.Compaction.Canonical.html): canonical JSON and hashes
- [`BeamWeaver.Compaction.ToolProjection`](https://hexdocs.pm/beam_weaver/BeamWeaver.Compaction.ToolProjection.html): shortened tool results and their replay
- [`BeamWeaver.Compaction.RehydrationState`](https://hexdocs.pm/beam_weaver/BeamWeaver.Compaction.RehydrationState.html): exact state kept beside the summary
- [`BeamWeaver.ContextBudget`](https://hexdocs.pm/beam_weaver/BeamWeaver.ContextBudget.html): how a request is measured against a context window
