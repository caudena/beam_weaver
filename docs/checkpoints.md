# Checkpoints and Time Travel

Checkpoints record state and pending execution at graph-step boundaries.
Use them to continue conversations, inspect a run, recover unfinished work,
or explore an earlier state. They do not make external side effects
exactly-once.

This page uses a deterministic local graph and an ETS saver. No provider key
is needed. Run the blocks in order in one IEx process.

## Save and inspect a workflow

```elixir
defmodule MyApp.CheckpointFlow do
  use BeamWeaver.Graph

  graph do
    node :classify, fn %{subject: subject} ->
      %{category: if(subject =~ ~r/refund/i, do: :billing, else: :shipping)}
    end

    node :reply, fn %{category: category} -> %{reply: "Route to #{category}."} end
    edge start(), :classify
    edge :classify, :reply
    edge :reply, finish()
  end
end

saver = BeamWeaver.Checkpoint.ETS.new()
config = %{"configurable" => %{"thread_id" => "ticket-42"}}
opts = [checkpointer: saver, config: config]
{:ok, _} = MyApp.CheckpointFlow.invoke(%{subject: "Refund for A-1001"}, opts)
{:ok, snapshot} = MyApp.CheckpointFlow.get_state(opts)
"Route to billing." = snapshot.values.reply
[] = snapshot.next

alias BeamWeaver.Graph.Compiled
{:ok, graph} = MyApp.CheckpointFlow.compiled_graph(checkpointer: saver)
history = Compiled.get_state_history(graph, config)
[[], ["reply"], ["classify"]] = Enum.map(history, & &1.next)
```

History is newest first. The input checkpoint schedules classification; the
next schedules the reply; the completed checkpoint has no pending node.

## Threads and checkpoints

A thread ID selects a sequence of saved states. A checkpoint ID selects one
specific point. Checkpoint namespaces distinguish nested graphs in the same
thread. Store those identifiers in application records so work can be found
after a restart; they are not an authorization mechanism.

## Read a checkpoint

| Snapshot field | Meaning |
| --- | --- |
| `values` | State visible at this checkpoint |
| `next` | Nodes still to execute |
| `config`, `parent_config` | This checkpoint's identity and predecessor |
| `metadata` | Source, step and run ID |
| `created_at` | Save time |
| `interrupts` | Waiting review/data requests |
| `pending_writes`, `tasks` | Progress from a partially completed step |

`get_state` returns `:error` for an unknown thread/checkpoint. To inspect an
older point, pass its returned config:

```elixir
before_reply = Enum.find(history, &(&1.next == ["reply"]))
{:ok, old} = MyApp.CheckpointFlow.get_state(checkpointer: saver, config: before_reply.config)
:billing = old.values.category
false = Map.has_key?(old.values, :reply)
```

## List the history

`Compiled.get_state_history/3` supports `limit:`, `before: snapshot.config`
and metadata `filter:`. Compile a module with the same saver to use these
inspection functions. Agents use the same API: their model/tool/hook steps
produce checkpoints too.

Limit the page and use its last config as the cursor for older entries:

```elixir
latest = BeamWeaver.Graph.Compiled.get_state_history(graph, config, limit: 2)
2 = length(latest)
older = BeamWeaver.Graph.Compiled.get_state_history(graph, config, before: List.last(latest).config)
true = length(older) > 0
IO.inspect(Enum.map(latest ++ older, &{&1.metadata["step"], &1.next}))
```

## Update state from outside a run

An update creates a new checkpoint; it does not mutate an existing one.
Values pass through their normal reducers:

```elixir
{:ok, updated_config} = Compiled.update_state(graph, config, %{reply: "A teammate will follow up."})
{:ok, updated} = Compiled.get_state(graph, updated_config)
"A teammate will follow up." = updated.values.reply
"update" = updated.metadata["source"]
```

By default, the update is attributed to the last node and its outgoing route
is evaluated again. Use `as_node:` when choosing that attribution explicitly.
If several nodes completed together and attribution is ambiguous, the update
fails with `:ambiguous_state_update`. Treat state editing as a privileged
operation because it can alter what runs next.

## Replay from an earlier checkpoint

```elixir
{:ok, replayed} = MyApp.CheckpointFlow.invoke(%{}, checkpointer: saver, config: before_reply.config)
"Route to billing." = replayed.reply
```

Nodes before the selected checkpoint are not rerun. Pending and subsequent
nodes execute again and append new history. The latest replay result becomes
the thread's latest state. Replaying a completed checkpoint executes no nodes.
Model/API calls after the selected point can be repeated; make side effects
idempotent and distinguish replay from a harmless read.

## Fork from an earlier checkpoint

Create a separate thread when the original should keep its latest state:

```elixir
{:ok, fork} = BeamWeaver.Checkpoint.fork_at(saver, before_reply.config, "ticket-42-alternative")
{:ok, fork} = Compiled.update_state(graph, fork, %{category: :shipping})
{:ok, alternative} = MyApp.CheckpointFlow.invoke(%{}, checkpointer: saver, config: fork)
"Route to shipping." = alternative.reply
{:ok, original} = MyApp.CheckpointFlow.get_state(opts)
"Route to billing." = original.values.reply
```

Updating an old checkpoint within the same thread also branches history, but
its final result becomes that thread's latest state. Choose the form that
matches your application's review/audit workflow.

## Pending writes

When one parallel node fails, successful siblings can finish and save their
updates as pending writes. The latest snapshot includes those successful
values and lists only unfinished work in `next`. Continuing does not rerun
successful siblings. `Send` tasks are tracked individually.

An ordinary state update preserves unfinished work. Updating `as_node:` the
failed node instead supplies its result and can skip its execution. Record
why that substitution is valid. Pending writes protect state progress, not
external side effects that happened before a failed node returned.

Here one local branch succeeds while the other raises. Only the failed branch remains pending:

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

An ordinary edit changes the value without marking the failed branch complete:

```elixir
{:ok, _config} = Compiled.update_state(parallel, failed, %{order_status: "shipped on Monday"})

{:ok, snapshot} = Compiled.get_state(parallel, failed)
{snapshot.values, snapshot.next}
#=> {%{order_status: "shipped on Monday"}, ["check_carrier"]}
```

If an operator obtained the carrier result independently, attribute the update to that node:

```elixir
{:ok, _config} =
  Compiled.update_state(parallel, failed, %{carrier: "checked by phone"}, as_node: :check_carrier)

{:ok, snapshot} = Compiled.get_state(parallel, failed)
{snapshot.values, snapshot.next}
#=> {%{order_status: "shipped on Monday", carrier: "checked by phone"}, []}
```

## Checkpoints and interrupts

A pending interrupt retains the input/review needed for continuation. Read it
from the snapshot and resume with the same thread, saver and fresh context.
Use `resume_review` for tool review and `resume` for graph answers/breakpoints.
[Human Review](human_in_the_loop.md) covers multiple and nested pauses.

Inspect a saved approval request before answering:

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

A replay of the paused checkpoint asks again and can take a different decision:

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

Correcting state before resume changes the input seen by the approval node:

```elixir
corrected = [checkpointer: saver, config: %{"configurable" => %{"thread_id" => "ticket-47"}}]
{:interrupted, _interrupt} = MyApp.RefundApproval.invoke(%{order_id: "A-1002"}, corrected)

{:ok, _config} = Compiled.update_state(approval_graph, corrected[:config], %{order_id: "A-1003"})
MyApp.RefundApproval.resume("yes", corrected)
#=> {:ok, %{order_id: "A-1003", approved: true}}
```

## Savers

ETS belongs to its creating process and disappears when that owner exits.
It is useful for local workflows and tests, but does not establish restart
durability. `Checkpoint.Ecto` uses a supervised PostgreSQL or SQLite repo;
[Storage](storage.md) contains the setup and migrations.

Graph modules accept a saver per call. A compiled graph receives it when
compiled. Do not allocate a new ETS saver inside a repeated declaration.

## Manage checkpoints

| Operation | Effect |
| --- | --- |
| `delete_thread` | Delete the thread's checkpoint history |
| `prune` | Keep latest state and required delta dependencies; remove expendable history |
| `delete_for_runs` | Delete named runs unless later delta history depends on them |
| `copy_thread` | Copy a full thread |
| `fork_at` | Copy history through one checkpoint into another thread |

```elixir
:ok = BeamWeaver.Checkpoint.prune(saver, ["ticket-42-alternative"])
:ok = BeamWeaver.Checkpoint.delete_thread(saver, "ticket-42-alternative")

:error =
  MyApp.CheckpointFlow.get_state(
    checkpointer: saver,
    config: %{"configurable" => %{"thread_id" => "ticket-42-alternative"}}
  )
```

Ecto `shallow?: true` retains only the state needed for continuation rather
than a full time-travel history. Define retention around your product's audit
and deletion requirements. Check returned errors before assuming deletion
succeeded; delta dependencies can prevent unsafe history removal.

## Write a custom saver

Implement `BeamWeaver.Checkpoint.Saver` on a struct. Core callbacks read tuples
and history, write checkpoints/pending writes, version channels and manage
threads. Delta-channel history must remain reconstructable.

Optional result-returning reads can distinguish missing data from storage
failure. Optional atomic writes/batches/forks support richer operations;
unsupported optional operations return errors. A wrapper must delegate the
full required contract. Adding tenant metadata is not access isolation unless
reads, writes and maintenance operations also enforce tenant boundaries.

This wrapper adds audit metadata while forwarding storage operations. It does not isolate tenants; enforce access at your application boundary:

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

{:ok, _state} = MyApp.CheckpointFlow.invoke(%{subject: "Where is order A-1001?"}, tenant_opts)
{:ok, snapshot} = MyApp.CheckpointFlow.get_state(tenant_opts)
snapshot.metadata["tenant"]
#=> "acme"
```
