defmodule BeamWeaver.Graph do
  @moduledoc """
  Idiomatic Elixir graph API for BeamWeaver.

  The public surface mirrors LangGraph behavior without copying Python's object
  model. Builders are immutable structs; compiled graphs execute under BEAM
  supervision primitives and checkpoint through `BeamWeaver.Checkpoint.Saver`.
  """

  alias BeamWeaver.Graph.ChannelSpec
  alias BeamWeaver.Graph.Compiled
  alias BeamWeaver.Graph.Execution.Scratchpad
  alias BeamWeaver.Graph.StateGraph

  @start :__start__
  @finish :__end__

  @type node_name :: atom() | String.t()

  @doc "Start sentinel used when declaring graph entry edges."
  def start, do: @start

  @doc "End sentinel used when declaring graph finish edges."
  def end_node, do: @finish

  @doc "Declares a state-schema channel using explicit Elixir data."
  @spec channel(term(), keyword()) :: ChannelSpec.t()
  def channel(channel, opts \\ []), do: ChannelSpec.new(channel, opts)

  @doc "Declares a private state-schema channel hidden from public outputs and checkpoints."
  @spec private_channel(term(), keyword()) :: ChannelSpec.t()
  def private_channel(channel, opts \\ []), do: ChannelSpec.private(channel, opts)

  @doc "Declares a managed runtime value in a state schema."
  @spec managed(term(), keyword()) :: ChannelSpec.t()
  def managed(managed, opts \\ []), do: ChannelSpec.managed(managed, opts)

  @spec new(keyword()) :: StateGraph.t()
  defdelegate new(opts \\ []), to: StateGraph

  @spec add_node(StateGraph.t(), node_name(), function() | module() | struct(), keyword()) ::
          StateGraph.t()
  defdelegate add_node(graph, name, fun, opts \\ []), to: StateGraph

  @spec set_node_defaults(StateGraph.t(), keyword()) :: StateGraph.t()
  defdelegate set_node_defaults(graph, opts), to: StateGraph

  @spec add_sequence(StateGraph.t(), list(), keyword()) :: StateGraph.t()
  defdelegate add_sequence(graph, sequence, opts \\ []), to: StateGraph

  @spec add_edge(StateGraph.t(), node_name(), node_name()) :: StateGraph.t()
  defdelegate add_edge(graph, start_node, end_node), to: StateGraph

  @spec add_edge(StateGraph.t(), node_name(), node_name(), keyword()) :: StateGraph.t()
  defdelegate add_edge(graph, start_node, end_node, opts), to: StateGraph

  @spec add_reducer(StateGraph.t(), atom() | String.t(), function()) :: StateGraph.t()
  defdelegate add_reducer(graph, key, reducer), to: StateGraph

  @spec add_channel(StateGraph.t(), atom() | String.t(), term(), keyword()) :: StateGraph.t()
  defdelegate add_channel(graph, key, channel, opts \\ []), to: StateGraph

  @spec compile(StateGraph.t(), keyword()) :: {:ok, Compiled.t()} | {:error, term()}
  defdelegate compile(graph, opts \\ []), to: StateGraph

  @spec compile!(StateGraph.t(), keyword()) :: Compiled.t()
  defdelegate compile!(graph, opts \\ []), to: StateGraph

  @doc "Returns all currently-known graph validation diagnostics without compiling."
  @spec validation_report(StateGraph.t(), keyword()) :: BeamWeaver.Graph.Validation.Report.t()
  def validation_report(graph, opts \\ []), do: BeamWeaver.Graph.Validation.report(graph, opts)

  @doc "Explicit `nil` resume marker for `BeamWeaver.Graph.interrupt/1`."
  @spec null_resume() :: BeamWeaver.Graph.Resume.t()
  def null_resume, do: BeamWeaver.Graph.Resume.null()

  @doc """
  Interrupts the current graph node and returns the resume value when resumed.

  This mirrors LangGraph's human-in-the-loop `interrupt(value)` behavior while
  keeping the public BeamWeaver API as a normal Elixir function.
  """
  @spec interrupt(term()) :: term() | no_return()
  def interrupt(value), do: Scratchpad.interrupt(value)
end
