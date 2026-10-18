# Checkpoints and Time Travel

A checkpointer saves the state of a graph or agent after every step, and it
keeps all of those checkpoints, not only the latest. Use the history to see
what a run did, to correct its state from outside, or to run it again from an
earlier step, as it was or with different values.

```elixir
defmodule MyApp.TicketTriage do
  use BeamWeaver.Graph

  alias BeamWeaver.Graph

  def graph do
    Graph.new()
    |> Graph.add_node(:classify, &classify/1)
    |> Graph.add_node(:reply, &reply/1)
    |> Graph.add_edge(Graph.start(), :classify)
    |> Graph.add_edge(:classify, :reply)
    |> Graph.add_edge(:reply, Graph.end_node())
  end

  def classify(%{subject: subject}) do
    %{category: if(subject =~ ~r/refund/i, do: :billing, else: :shipping)}
  end

  def reply(%{category: category}), do: %{reply: "Routed to the #{category} queue."}
end

saver = BeamWeaver.Checkpoint.ETS.new()
config = %{"configurable" => %{"thread_id" => "ticket-42"}}
opts = [checkpointer: saver, config: config]

{:ok, _state} = MyApp.TicketTriage.invoke(%{subject: "Refund for order A-1001"}, opts)

{:ok, graph} = MyApp.TicketTriage.compiled_graph(checkpointer: saver)
history = BeamWeaver.Graph.Compiled.get_state_history(graph, config)

Enum.map(history, & &1.next)
#=> [[], ["reply"], ["classify"]]
```

The run left three checkpoints, newest first: after `reply`, with nothing
left to run; after `classify`, with `reply` next; and the input, with
`classify` next. The sections below read, change and rerun them.

## Threads and checkpoints

A thread is one conversation or workflow run, named by the `thread_id` in
`config:`. Every step of a run ends with a checkpoint: the whole state, the
nodes that run next, and facts about the step. For an agent, every model
call, tool round and middleware hook is a step. A later call on the same
thread starts from its latest checkpoint, and a paused, failed or stopped run
continues from it: `resume/2`, or `invoke/2` with an empty input, runs the
nodes in its `next`.
[Short-Term Memory](short_term_memory.md) shows the everyday use: an agent
that remembers a conversation.

## Savers

The checkpointer you pass is a saver, a struct that stores the checkpoints.
`BeamWeaver.Checkpoint.ETS` keeps them in memory, for tests and development.
Create it once and pass it with `checkpointer:` on every call, as above. A
module that declares `checkpointer BeamWeaver.Checkpoint.ETS.new()` doesn't
compile: declarations are evaluated on every call, so each call would get a
new, empty saver. A declared function, such as
`checkpointer MyApp.AgentStorage.checkpointer()`, must return the same saver
every time; when it returns a new ETS saver, the agent logs a warning on its
first call. The saver's tables belong to the process that created it and
disappear with that process.

In production, use `BeamWeaver.Checkpoint.Ecto`, which stores checkpoints in
Postgres or SQLite; [Storage](storage.md) covers its migrations. It is a plain
struct, so you can build it where you need it, or declare it in the module
with `checkpointer BeamWeaver.Checkpoint.Ecto.new(repo: MyApp.Repo)`:

```elixir
MyApp.TicketTriage.invoke(%{subject: "Refund for order A-1001"},
  checkpointer: BeamWeaver.Checkpoint.Ecto.new(repo: MyApp.Repo),
  config: %{"configurable" => %{"thread_id" => "ticket-42"}}
)
```

A graph you compile yourself takes its saver at compile time,
`Graph.compile!(graph, checkpointer: saver)`. Everything on this page works
the same way with it.

## Read a checkpoint

`get_state/1` returns the latest checkpoint of a thread as a snapshot, or
`:error` when the thread has none:

```elixir
{:ok, snapshot} = MyApp.TicketTriage.get_state(opts)
{snapshot.values.reply, snapshot.next, snapshot.metadata["step"]}
#=> {"Routed to the billing queue.", [], 1}
```

| Field | What it holds |
|---|---|
| `values` | The state at this checkpoint. |
| `next` | The nodes that run next. `[]` means the run finished. |
| `config` | The thread id and this checkpoint's `checkpoint_id`. Pass it as `config:` to read, rerun or fork from this checkpoint. |
| `parent_config` | The `config` of the checkpoint before this one. |
| `metadata` | `"source"` (`"input"`, `"loop"` for a step, `"update"` or `"fork"`), `"step"` and `"run_id"`. |
| `created_at` | When it was saved, as an ISO 8601 string. |
| `interrupts` | Pauses waiting for `resume/2`. See [Checkpoints and interrupts](#checkpoints-and-interrupts). |
| `pending_writes` | Updates of a step that didn't finish. See [Pending writes](#pending-writes). |
| `tasks` | The nodes that started and finished in this step. |

To read an older checkpoint, pass its `config`. Store a checkpoint's config
in your own tables, for example next to a ticket, and you can come back to
exactly that point later:

```elixir
before_reply = Enum.find(history, &(&1.next == ["reply"]))

{:ok, old} = MyApp.TicketTriage.get_state(checkpointer: saver, config: before_reply.config)
old.values
#=> %{subject: "Refund for order A-1001", category: :billing}
```

## List the history

History and state edits are functions of the compiled graph,
`BeamWeaver.Graph.Compiled`. The `compiled_graph/1` of a graph or agent
module compiles its graph; give it the saver you run the module with, as in
the first example. `BeamWeaver.Graph.Compiled.get_state_history/3` returns a
thread's snapshots, newest first, and takes these options:

- `limit: 10` returns at most that many.
- `before: snapshot.config` returns only the checkpoints older than that one.
- `filter: %{"source" => "update"}` returns only the checkpoints whose
  metadata matches.

```elixir
alias BeamWeaver.Graph.Compiled

for snapshot <- Compiled.get_state_history(graph, config, limit: 2) do
  {snapshot.metadata["step"], snapshot.metadata["source"]}
end
#=> [{1, "loop"}, {0, "loop"}]
```

Agents are graphs too, so the same calls list a conversation. Each turn adds
an input checkpoint and one checkpoint per step; this agent has no tools, so
its only step is the model call:

```elixir
defmodule MyApp.SupportAgent do
  use BeamWeaver.Agent

  model "fake:chat", responses: ["Order A-1001 shipped on Monday."]
  system_prompt "You are Acme's support agent."
end

chat = [checkpointer: saver, config: %{"configurable" => %{"thread_id" => "ticket-43"}}]
{:ok, _state} = MyApp.SupportAgent.invoke(%{messages: ["Where is order A-1001?"]}, chat)

{:ok, agent_graph} = MyApp.SupportAgent.compiled_graph(checkpointer: saver)
agent_graph |> Compiled.get_state_history(chat[:config]) |> Enum.map(& &1.next)
#=> [[], ["model"]]
```

## Update state from outside a run

`BeamWeaver.Graph.Compiled.update_state/4` writes a new checkpoint on top of
the one that its config names, or on top of the latest one when the config
has no `checkpoint_id`. It never changes a saved checkpoint. The values merge
into the state the way a node's result does, so keys with a reducer add up.
It returns the config of the new checkpoint:

```elixir
{:ok, _new_config} =
  Compiled.update_state(graph, config, %{reply: "Routed to the billing queue. Ada gets a call today."})

{:ok, snapshot} = MyApp.TicketTriage.get_state(opts)
{snapshot.values.reply, snapshot.metadata["source"]}
#=> {"Routed to the billing queue. Ada gets a call today.", "update"}
```

BeamWeaver treats the update as the result of the node that ran last and
schedules the nodes after it. Here `reply` ran last, so nothing runs next.
The update replaces that node's result, so its edges choose again; the nodes
that other branches, or a `Command`'s `goto`, put next still run. Pass
`as_node: :classify` to pick the node yourself, for example to skip a node
by writing its result for it. When several nodes ran in the last step and
you don't pass `as_node:`, the update fails with
`{:error, %BeamWeaver.Core.Error{type: :ambiguous_state_update}}`.

## Replay from an earlier checkpoint

To run a thread again from an earlier step, invoke it with an empty input
and that checkpoint's config. The nodes before the checkpoint don't run; the
nodes in its `next`, and the ones after them, do:

```elixir
{:ok, state} = MyApp.TicketTriage.invoke(%{}, checkpointer: saver, config: before_reply.config)
state.reply
#=> "Routed to the billing queue."
```

The old checkpoints don't change. The replay adds a `"fork"` checkpoint, a
copy of the one you picked, then one checkpoint per step it ran, and its last
checkpoint is now the thread's latest:

```elixir
graph |> Compiled.get_state_history(config) |> Enum.map(& &1.metadata["source"])
#=> ["loop", "fork", "update", "loop", "loop", "input"]
```

{% hint style="warning" %}
**A replay runs your nodes again.** Model calls, API calls and other side
effects after the checkpoint happen a second time; make them safe to repeat
(see [Durable Execution](durable_execution.md#determinism-and-side-effects)).
Replaying a checkpoint whose `next` is empty runs nothing.
{% endhint %}

## Fork from an earlier checkpoint

To try a different path, update an earlier checkpoint, then run from the
checkpoint that the update returns:

```elixir
{:ok, fork_config} = Compiled.update_state(graph, before_reply.config, %{category: :shipping})

{:ok, state} = MyApp.TicketTriage.invoke(%{}, checkpointer: saver, config: fork_config)
state.reply
#=> "Routed to the shipping queue."
```

The fork starts at `before_reply`, and the original run stays in the history.
The fork's last checkpoint is now the thread's latest, so the next call on
`"ticket-42"` continues from it.

To leave a thread as it is, fork into a new thread instead.
`BeamWeaver.Checkpoint.fork_at/4` copies a checkpoint and the checkpoints
before it to another thread id, and returns the config of the copy:

```elixir
{:ok, retry} = BeamWeaver.Checkpoint.fork_at(saver, before_reply.config, "ticket-42-retry")

{:ok, state} = MyApp.TicketTriage.invoke(%{}, checkpointer: saver, config: retry)
state.reply
#=> "Routed to the billing queue."
```

## Pending writes

When several nodes run in one step and one of them fails, the others still
finish. BeamWeaver saves their updates, and the error, as pending writes of
the last checkpoint before it returns `{:error, error}`. The latest snapshot
applies them: its `values` include the updates that succeeded, and its `next`
lists only the nodes that still have to run.

```elixir
alias BeamWeaver.Graph

parallel =
  Graph.new()
  |> Graph.add_node(:lookup_order, fn _state -> %{order_status: "shipped"} end)
  |> Graph.add_node(:check_carrier, fn _state -> raise "carrier API is down" end)
  |> Graph.add_edge(Graph.start(), :lookup_order)
  |> Graph.add_edge(Graph.start(), :check_carrier)
  |> Graph.add_edge(:lookup_order, Graph.end_node())
  |> Graph.add_edge(:check_carrier, Graph.end_node())
  |> Graph.compile!(checkpointer: saver)

failed = %{"configurable" => %{"thread_id" => "ticket-44"}}
{:error, _error} = Compiled.invoke(parallel, %{}, config: failed)

{:ok, snapshot} = Compiled.get_state(parallel, failed)
{snapshot.values, snapshot.next}
#=> {%{order_status: "shipped"}, ["check_carrier"]}
```

`snapshot.pending_writes` lists the raw entries: the updates, the error, and
a `"__route__"` entry for each node that finished, which says where the run
goes from it. Continuing the thread runs only `check_carrier`; see
[Durable Execution](durable_execution.md#fan-out-and-pending-writes).
Updating the state of the failed thread keeps it that way: `next` still lists
`check_carrier`, and continuing runs it on the updated state:

```elixir
{:ok, _config} = Compiled.update_state(parallel, failed, %{order_status: "shipped on Monday"})

{:ok, snapshot} = Compiled.get_state(parallel, failed)
{snapshot.values, snapshot.next}
#=> {%{order_status: "shipped on Monday"}, ["check_carrier"]}
```

To skip the failed node instead, update the state as that node. The update
is its result, so it doesn't run again, and the step goes on from it; here
nothing comes after it:

```elixir
{:ok, _config} =
  Compiled.update_state(parallel, failed, %{carrier: "checked by phone"}, as_node: :check_carrier)

{:ok, snapshot} = Compiled.get_state(parallel, failed)
{snapshot.values, snapshot.next}
#=> {%{order_status: "shipped on Monday", carrier: "checked by phone"}, []}
```

## Checkpoints and interrupts

A paused run is saved like any other step. Its snapshot lists the pause in
`interrupts` and the paused node in `next`, so `get_state/1` tells you which
threads wait for a person. [Human-in-the-Loop](human_in_the_loop.md) covers
pausing and resuming. This graph asks before it refunds:

```elixir
defmodule MyApp.RefundApproval do
  use BeamWeaver.Graph

  alias BeamWeaver.Graph

  def graph do
    Graph.new()
    |> Graph.add_node(:approve, &approve/1)
    |> Graph.add_edge(Graph.start(), :approve)
    |> Graph.add_edge(:approve, Graph.end_node())
  end

  def approve(%{order_id: order_id}) do
    %{approved: Graph.interrupt(%{question: "Refund order #{order_id}?"}) == "yes"}
  end
end

approval = [checkpointer: saver, config: %{"configurable" => %{"thread_id" => "ticket-45"}}]
{:interrupted, _interrupt} = MyApp.RefundApproval.invoke(%{order_id: "A-1001"}, approval)

{:ok, snapshot} = MyApp.RefundApproval.get_state(approval)
{snapshot.next, Enum.map(snapshot.interrupts, & &1.value)}
#=> {["approve"], [%{question: "Refund order A-1001?"}]}
```

Time travel works across pauses. Replaying the checkpoint where the run
paused runs the node again, so it pauses again and takes a new answer:

```elixir
{:ok, %{approved: true}} = MyApp.RefundApproval.resume("yes", approval)

{:ok, approval_graph} = MyApp.RefundApproval.compiled_graph(checkpointer: saver)

paused =
  approval_graph
  |> Compiled.get_state_history(approval[:config])
  |> Enum.find(&(&1.interrupts != []))

{:interrupted, _interrupt} = MyApp.RefundApproval.invoke(%{}, checkpointer: saver, config: paused.config)
MyApp.RefundApproval.resume("no", approval)
#=> {:ok, %{order_id: "A-1001", approved: false}}
```

To change what a paused node works with, update the state of the paused
thread. The thread stays paused, and the next resume runs the node on the
updated state:

```elixir
corrected = [checkpointer: saver, config: %{"configurable" => %{"thread_id" => "ticket-47"}}]
{:interrupted, _interrupt} = MyApp.RefundApproval.invoke(%{order_id: "A-1002"}, corrected)

{:ok, _config} = Compiled.update_state(approval_graph, corrected[:config], %{order_id: "A-1003"})
MyApp.RefundApproval.resume("yes", corrected)
#=> {:ok, %{order_id: "A-1003", approved: true}}
```

## Manage checkpoints

Every step of every run adds a checkpoint, and checkpoints stay until you
remove them. These functions of `BeamWeaver.Checkpoint` clean up and copy
threads:

| Function | What it does |
|---|---|
| `delete_thread(saver, thread_id)` | Deletes every checkpoint of a thread. |
| `prune(saver, thread_ids)` | Keeps the latest checkpoint of each thread, and the earlier ones its delta channels still read: the threads continue, but the rest of their history is gone, with the checkpoints of subgraph calls that finished. With `strategy: :delete` it deletes the threads; any other strategy returns an `:invalid_prune_strategy` error. |
| `delete_for_runs(saver, run_ids)` | Deletes the checkpoints that the given runs wrote (`metadata["run_id"]`). When a later checkpoint reads delta channel history from them, it deletes nothing and returns a `:delta_history_in_use` error. |
| `copy_thread(saver, from_id, to_id)` | Copies a whole thread to a new thread id. |
| `fork_at(saver, config, thread_id)` | Copies one checkpoint and the ones before it to a new thread id. |

```elixir
alias BeamWeaver.Checkpoint

:ok = Checkpoint.prune(saver, ["ticket-42"])
graph |> Compiled.get_state_history(config) |> length()
#=> 1
```

```elixir
:ok = Checkpoint.delete_thread(saver, "ticket-42")
MyApp.TicketTriage.get_state(opts)
#=> :error
```

Run these from a periodic job, with the thread ids your application keeps,
for example for tickets closed more than 30 days ago. When you never need
the history, `Checkpoint.Ecto.new(repo: MyApp.Repo, shallow?: true)` keeps
only the latest checkpoint of each thread: runs still pause and continue,
but there is nothing to travel back to.

## Write a custom saver

A saver is a struct whose module implements the
`BeamWeaver.Checkpoint.Saver` behaviour. A run reads checkpoints with
`get_tuple` and `list` and writes them with `put` and `put_writes`:

| Callback | What it does |
|---|---|
| `get_tuple/2` | Returns the checkpoint that the config names, or the latest one, with its pending writes; `nil` when there is none. |
| `list/3` | Returns checkpoints newest first, honoring `limit:`, `before:` and `filter:`. |
| `put/5` | Saves a checkpoint and returns its config, with the new `checkpoint_id`. |
| `put_writes/5` | Saves pending writes for a checkpoint. |
| `get_delta_channel_history/4` | Returns earlier writes of keys stored as deltas, such as an agent's messages. |
| `next_version/3` | Returns the next version number of a state key. |
| `delete_thread/2`, `delete_for_runs/2`, `copy_thread/3`, `prune/3` | Back the functions with the same names in [Manage checkpoints](#manage-checkpoints). |

The optional `fetch_tuple/2` and `list_result/3` are versions of `get_tuple`
and `list` that return `{:error, reason}` when the storage fails. The optional
`put_checkpoint_with_writes/7`, `put_many/3` and `fork_at/4` back the
functions of `BeamWeaver.Checkpoint` with the same names, which return an
error for a saver without them.

The quickest custom saver wraps an existing one. This one stamps the tenant
on every checkpoint and hands each call to the saver inside it:

```elixir
defmodule MyApp.TenantSaver do
  @behaviour BeamWeaver.Checkpoint.Saver

  defstruct [:inner, :tenant]

  def new(inner, tenant), do: %__MODULE__{inner: inner, tenant: tenant}

  def put(saver, config, checkpoint, metadata, versions),
    do: call(saver, :put, [config, checkpoint, Map.put(metadata, "tenant", saver.tenant), versions])

  def put_writes(saver, config, writes, task_id, path),
    do: call(saver, :put_writes, [config, writes, task_id, path])

  def get_delta_channel_history(saver, config, keys, opts),
    do: call(saver, :get_delta_channel_history, [config, keys, opts])

  def get_tuple(saver, config), do: call(saver, :get_tuple, [config])
  def list(saver, config, opts), do: call(saver, :list, [config, opts])
  def delete_thread(saver, thread_id), do: call(saver, :delete_thread, [thread_id])
  def delete_for_runs(saver, run_ids), do: call(saver, :delete_for_runs, [run_ids])
  def copy_thread(saver, from_id, to_id), do: call(saver, :copy_thread, [from_id, to_id])
  def prune(saver, thread_ids, opts), do: call(saver, :prune, [thread_ids, opts])
  def next_version(saver, current, key), do: call(saver, :next_version, [current, key])

  defp call(%{inner: inner}, fun, args), do: apply(inner.__struct__, fun, [inner | args])
end

tenant_saver = MyApp.TenantSaver.new(BeamWeaver.Checkpoint.ETS.new(), "acme")
tenant_opts = [checkpointer: tenant_saver, config: %{"configurable" => %{"thread_id" => "ticket-46"}}]

{:ok, _state} = MyApp.TicketTriage.invoke(%{subject: "Where is order A-1001?"}, tenant_opts)
{:ok, snapshot} = MyApp.TicketTriage.get_state(tenant_opts)
snapshot.metadata["tenant"]
#=> "acme"
```

In production, wrap the Ecto saver:
`MyApp.TenantSaver.new(BeamWeaver.Checkpoint.Ecto.new(repo: MyApp.Repo), tenant)`.
`BeamWeaver.Checkpoint.list/3` with no config and
`filter: %{"tenant" => "acme"}` then finds a tenant's checkpoints across
threads.

## Reference

- [`BeamWeaver.Checkpoint`](https://hexdocs.pm/beam_weaver/BeamWeaver.Checkpoint.html): listing, copying, pruning and deleting checkpoints
- [`BeamWeaver.Checkpoint.ETS`](https://hexdocs.pm/beam_weaver/BeamWeaver.Checkpoint.ETS.html): in-memory saver for development and tests
- [`BeamWeaver.Checkpoint.Ecto`](https://hexdocs.pm/beam_weaver/BeamWeaver.Checkpoint.Ecto.html): Postgres and SQLite saver
- [`BeamWeaver.Checkpoint.Saver`](https://hexdocs.pm/beam_weaver/BeamWeaver.Checkpoint.Saver.html): the behaviour for custom savers
- [`BeamWeaver.Graph.Compiled`](https://hexdocs.pm/beam_weaver/BeamWeaver.Graph.Compiled.html): `get_state_history/3`, `update_state/4` and running compiled graphs
- [`BeamWeaver.Agent`](https://hexdocs.pm/beam_weaver/BeamWeaver.Agent.html): `compiled_graph/2`, `invoke/3` and `get_state/2`
- [`BeamWeaver.Graph`](https://hexdocs.pm/beam_weaver/BeamWeaver.Graph.html): the `compiled_graph/1` of graph and agent modules
