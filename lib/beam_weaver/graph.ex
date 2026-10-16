defmodule BeamWeaver.Graph do
  @moduledoc ~S"""
  Builds workflows from nodes and edges.

  A node is a function that receives the state and returns a map of the keys
  it changes. Edges say which node runs next. Build a graph with the functions
  in this module, compile it, and run it with `BeamWeaver.Graph.Compiled`:

  ```elixir
  alias BeamWeaver.Graph
  alias BeamWeaver.Graph.Compiled

  triage =
    Graph.new()
    |> Graph.add_node(:classify, fn %{subject: subject} ->
      %{category: if(subject =~ ~r/refund/i, do: :billing, else: :general)}
    end)
    |> Graph.add_node(:reply, fn %{category: category} -> %{reply: "Routed to the #{category} queue."} end)
    |> Graph.add_edge(Graph.start(), :classify)
    |> Graph.add_edge(:classify, :reply)
    |> Graph.add_edge(:reply, Graph.end_node())
    |> Graph.compile!()

  {:ok, state} = Compiled.invoke(triage, %{subject: "Refund for order A-1001"})
  state.reply
  #=> "Routed to the billing queue."
  ```

  In an application, return the graph from the `graph/0` function of a module
  with `use BeamWeaver.Agent`; the module then gets `invoke/2`,
  `stream_events/2` and `resume/2`.

  The [Graphs](graphs.md) guide covers routing, parallel branches, `Command`
  and `Send`; [Graph State](graph_state.md) covers how updates merge.
  """

  alias BeamWeaver.Graph.ChannelSpec
  alias BeamWeaver.Graph.Compiled
  alias BeamWeaver.Graph.Execution.Scratchpad
  alias BeamWeaver.Graph.StateGraph

  @start :__start__
  @finish :__end__

  @typedoc "A graph being built: start one with `new/1`, then add nodes and edges."
  @type t :: struct()

  @typedoc "A state key declaration from `channel/2`, `private_channel/2` or `managed/2`."
  @type channel_spec :: struct()

  @typedoc "A node name. `start/0` and `end_node/0` name the entry and the exit."
  @type node_name :: atom() | String.t()

  @doc "The entry of a graph, for edges such as `add_edge(graph, Graph.start(), :first)`."
  def start, do: @start

  @doc "The exit of a graph, for edges such as `add_edge(graph, :last, Graph.end_node())`."
  def end_node, do: @finish

  @doc """
  Declares a state key with an explicit channel, for the `state_schema:` option
  of `new/1`.

  `channel` is a channel module such as `BeamWeaver.Graph.Channels.LastValue`,
  or `{module, arg}`, such as `{BeamWeaver.Graph.Channels.BinaryOperatorAggregate, &Kernel.+/2}`.
  See [Graph State](graph_state.md).
  """
  @spec channel(term(), keyword()) :: channel_spec()
  def channel(channel, opts \\ []), do: ChannelSpec.new(channel, opts)

  @doc """
  Like `channel/2`, for a key that is left out of the run's output and its checkpoints.

  With `checkpoint: true` the key is still left out of the output, but it is
  saved in checkpoints, so the next run on the same thread starts from its
  value. Use it for bookkeeping that belongs to the thread, such as a count of
  model calls.
  """
  @spec private_channel(term(), keyword()) :: channel_spec()
  def private_channel(channel, opts \\ []), do: ChannelSpec.private(channel, opts)

  @doc """
  Declares a managed value: a key computed by the runtime, such as
  `BeamWeaver.Graph.Managed.RemainingSteps`, instead of written by nodes.
  """
  @spec managed(term(), keyword()) :: channel_spec()
  def managed(managed, opts \\ []), do: ChannelSpec.managed(managed, opts)

  @doc """
  Starts an empty graph.

  Options:

    * `:name` - the graph's name in traces and errors.
    * `:state_schema` - a map of state keys to `channel/2` declarations.
    * `:reducers` - a map of state keys to two-argument merge functions; see
      `add_reducer/3`.
    * `:input_schema`, `:output_schema` - the keys the graph accepts and returns.
    * `:node_defaults` - options every node gets; see `set_node_defaults/2`.
  """
  @spec new(keyword()) :: t()
  defdelegate new(opts \\ []), to: StateGraph

  @doc """
  Adds a node.

  `fun` takes the state, or the state and the run's runtime, and returns a map
  of the keys it changes, a `BeamWeaver.Graph.Command`, a list of
  `BeamWeaver.Graph.Send`, or `{:error, reason}` to fail. A compiled graph, or
  a module with `use BeamWeaver.Agent`, runs as a subgraph, and the keys it
  changed become the node's update.

  Options:

    * `:retry` - run the node again when it fails, such as
      `[max_attempts: 3, initial_delay: 200]` (see `BeamWeaver.RetryPolicy`).
    * `:timeout` - milliseconds one attempt of the node may run. By default it
      has no limit (`:infinity`).
    * `:error_handler` - `fn error, state, runtime -> update end`, called when
      the node still fails after its retries.
    * `:cache` - reuse the result for the same input, such as `[ttl: 60_000]`;
      compile with a `:cache`.
    * `:deps` - nodes that must finish first.
    * `:input`, `:output` - reshape the state the node sees and the update it returns.
    * `:destinations` - the nodes a `Command` or `Send` from this node may go
      to, for drawings and `validation_report/2`.
  """
  @spec add_node(t(), node_name(), function() | module() | struct(), keyword()) :: t()
  defdelegate add_node(graph, name, fun, opts \\ []), to: StateGraph

  @doc "Sets options that every node gets unless it sets them itself."
  @spec set_node_defaults(t(), keyword()) :: t()
  defdelegate set_node_defaults(graph, opts), to: StateGraph

  @doc """
  Adds nodes that run one after another: `[{name, fun}, ...]`, or
  `{name, fun, node_opts}`. `opts` apply to every node.
  """
  @spec add_sequence(t(), list(), keyword()) :: t()
  defdelegate add_sequence(graph, sequence, opts \\ []), to: StateGraph

  @doc "Adds an edge: `end_node` runs after `start_node`."
  @spec add_edge(t(), node_name(), node_name()) :: t()
  defdelegate add_edge(graph, start_node, end_node), to: StateGraph

  @doc """
  Adds an edge that is taken only when the update `start_node` returned matches.

  Options:

    * `:when` - a map of keys to values, lists of values, ranges or
      one-argument functions that must all match, or a function of the update
      (or of the update and the state).
    * `:default` - `true` to take this edge when no `:when` edge matched.
    * `:max_runs` - how many times one run may take the edge. A new run on
      the thread counts from zero; a run that continues where the thread
      stopped keeps its count.
  """
  @spec add_edge(t(), node_name(), node_name(), keyword()) :: t()
  defdelegate add_edge(graph, start_node, end_node, opts), to: StateGraph

  @doc """
  Runs `downstream_node` once, after every node in `upstream_nodes` has finished.

  The upstream nodes may finish in different steps. Which of them have
  finished is saved with the thread's checkpoints, so the join also fires when
  the last one finishes in a later run, such as after an interrupt.
  """
  @spec add_join(t(), [node_name()], node_name(), keyword()) :: t()
  defdelegate add_join(graph, upstream_nodes, downstream_node, opts \\ []), to: StateGraph

  @doc """
  Merges updates to `key` with `reducer` instead of replacing the value:
  `reducer.(current, update)` returns the new value.
  """
  @spec add_reducer(t(), atom() | String.t(), function()) :: t()
  defdelegate add_reducer(graph, key, reducer), to: StateGraph

  @doc "Declares `key` with a channel; see `channel/2` and [Graph State](graph_state.md)."
  @spec add_channel(t(), atom() | String.t(), term(), keyword()) :: t()
  defdelegate add_channel(graph, key, channel, opts \\ []), to: StateGraph

  @doc """
  Checks the graph and compiles it for `BeamWeaver.Graph.Compiled`.

  Options:

    * `:checkpointer` - saves each step, for threads, interrupts and resuming.
    * `:store` - the memory store nodes can read.
    * `:cache` - the cache for nodes with a `:cache` option.
    * `:step_timeout`, `:run_timeout` - milliseconds for one step or the whole run.
    * `:name` - the compiled graph's name.
  """
  @spec compile(t(), keyword()) :: {:ok, Compiled.t()} | {:error, term()}
  defdelegate compile(graph, opts \\ []), to: StateGraph

  @doc "Like `compile/2`, but raises when the graph is invalid."
  @spec compile!(t(), keyword()) :: Compiled.t()
  defdelegate compile!(graph, opts \\ []), to: StateGraph

  @doc "Lists the problems `compile/2` would report, without compiling."
  @spec validation_report(t(), keyword()) :: BeamWeaver.Graph.Validation.Report.t()
  def validation_report(graph, opts \\ []), do: BeamWeaver.Graph.Validation.report(graph, opts)

  @doc "A resume value that makes `interrupt/1` return `nil`."
  @spec null_resume() :: BeamWeaver.Graph.Resume.t()
  def null_resume, do: BeamWeaver.Graph.Resume.null()

  @doc """
  Pauses the run inside the current node and hands `value` to the caller.

  The run returns `{:interrupted, interrupt}`. When it is resumed, the node
  runs again from the start, and this call returns the resume value. The graph
  needs a checkpointer. See [Human-in-the-Loop](human_in_the_loop.md).
  """
  @spec interrupt(term()) :: term() | no_return()
  def interrupt(value), do: Scratchpad.interrupt(value)
end
