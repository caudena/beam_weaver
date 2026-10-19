defmodule BeamWeaver.Graph.StateGraph do
  @moduledoc false

  alias BeamWeaver.Graph
  alias BeamWeaver.Graph.BranchSpec
  alias BeamWeaver.Graph.Channels.BinaryOperatorAggregate
  alias BeamWeaver.Graph.Channels.NamedBarrierValue
  alias BeamWeaver.Graph.GuardedEdgeSpec
  alias BeamWeaver.Graph.NodeSpec
  alias BeamWeaver.Graph.StateGraph.Normalization, as: N
  alias BeamWeaver.Graph.WaitingEdgeSpec

  defstruct name: "BeamWeaverGraph",
            reducers: %{},
            channels: %{},
            channel_subscriptions: %{},
            channel_visibility: %{},
            managed: %{},
            nodes: %{},
            edges: %{},
            guarded_edges: %{},
            conditional_edges: %{},
            waiting_edges: [],
            entry_points: [],
            finish_points: MapSet.new(),
            state_schema: nil,
            context_schema: nil,
            input_schema: nil,
            output_schema: nil,
            node_defaults: [],
            diagnostics: []

  @type t :: %__MODULE__{
          name: String.t(),
          reducers: map(),
          channels: map(),
          channel_subscriptions: map(),
          channel_visibility: map(),
          managed: map(),
          nodes: map(),
          edges: map(),
          guarded_edges: map(),
          conditional_edges: map(),
          entry_points: [String.t()],
          finish_points: term()
        }

  @spec new(keyword()) :: t()
  def new(opts) do
    reducers = N.normalize_reducers(Keyword.get(opts, :reducers, %{}))
    state_schema = Keyword.get(opts, :state_schema)

    {schema_channels, schema_subscriptions, schema_visibility, schema_managed} =
      N.channels_from_schema(state_schema)

    explicit_channels =
      opts
      |> Keyword.get(:channels, %{})
      |> N.normalize_channel_defs()

    channels =
      reducers
      |> N.reducer_channels()
      |> Map.merge(schema_channels)
      |> Map.merge(explicit_channels)
      |> Map.merge(internal_channels())

    %__MODULE__{
      name: to_string(Keyword.get(opts, :name, "BeamWeaverGraph")),
      reducers: reducers,
      channels: channels,
      channel_subscriptions: schema_subscriptions,
      channel_visibility: schema_visibility,
      managed: schema_managed,
      state_schema: state_schema,
      context_schema: Keyword.get(opts, :context_schema),
      input_schema: Keyword.get(opts, :input_schema),
      output_schema: Keyword.get(opts, :output_schema),
      node_defaults: Keyword.get(opts, :node_defaults, [])
    }
  end

  @spec add_node(t(), Graph.node_name(), function() | module() | struct(), keyword()) :: t()
  def add_node(%__MODULE__{} = graph, name, fun, opts) do
    node = N.normalize_node(name)

    spec =
      case NodeSpec.new(node, fun, Keyword.merge(graph.node_defaults, opts)) do
        {:ok, spec} -> spec
        {:error, error} -> %NodeSpec{name: node, fun: fun, kind: :invalid, metadata: %{error: error}, deps: []}
      end

    graph
    |> maybe_record_duplicate(:node, node, Map.has_key?(graph.nodes, node))
    |> then(&%{&1 | nodes: Map.put(&1.nodes, node, spec)})
    |> add_dependency_edges(spec)
  end

  @spec set_node_defaults(t(), keyword()) :: t()
  def set_node_defaults(%__MODULE__{} = graph, opts) when is_list(opts) do
    %{graph | node_defaults: Keyword.merge(graph.node_defaults, opts)}
  end

  @spec add_sequence(t(), list(), keyword()) :: t()
  def add_sequence(%__MODULE__{} = graph, sequence, opts) when is_list(sequence) do
    {graph, names} =
      Enum.reduce(sequence, {graph, []}, fn
        {name, callable}, {acc, names} ->
          node = N.normalize_node(name)
          {add_node(acc, node, callable, opts), names ++ [node]}

        {name, callable, node_opts}, {acc, names} when is_list(node_opts) ->
          node = N.normalize_node(name)
          {add_node(acc, node, callable, Keyword.merge(opts, node_opts)), names ++ [node]}

        name, {acc, names} ->
          {acc, names ++ [N.normalize_node(name)]}
      end)

    names
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.reduce(graph, fn [source, target], acc -> add_edge(acc, source, target) end)
  end

  @spec add_edge(t(), Graph.node_name(), Graph.node_name()) :: t()
  def add_edge(%__MODULE__{} = graph, start_node, end_node) do
    start_node = N.normalize_node(start_node)
    end_node = N.normalize_node(end_node)

    graph
    |> maybe_record_duplicate(:edge, {start_node, end_node}, end_node in Map.get(graph.edges, start_node, []))
    |> maybe_add_entry(start_node, end_node)
    |> maybe_add_finish(start_node, end_node)
    |> put_edge(start_node, end_node)
  end

  @spec add_edge(t(), Graph.node_name(), Graph.node_name(), keyword()) :: t()
  def add_edge(%__MODULE__{} = graph, start_node, end_node, opts) when is_list(opts) do
    if guarded_edge_options?(opts) do
      add_guarded_edge(graph, start_node, end_node, opts)
    else
      add_edge(graph, start_node, end_node)
    end
  end

  @spec add_join(t(), [Graph.node_name()], Graph.node_name(), keyword()) :: t()
  def add_join(%__MODULE__{} = graph, upstream_nodes, downstream_node, opts) do
    upstream = upstream_nodes |> List.wrap() |> Enum.map(&N.normalize_node/1) |> Enum.uniq()
    target = N.normalize_node(downstream_node)
    id = Keyword.get(opts, :id, waiting_edge_id(upstream, target))
    channel = "__barrier__:" <> to_string(id)

    spec = %WaitingEdgeSpec{
      id: to_string(id),
      channel: channel,
      upstream: upstream,
      target: target,
      metadata: Keyword.get(opts, :metadata, %{})
    }

    # The join's channel is internal: hidden from nodes and results, but saved
    # with the thread so that a join survives a failed step that is retried.
    graph
    |> add_channel(channel, NamedBarrierValue.new(upstream, key: channel), subscribers: [target])
    |> then(&%{&1 | waiting_edges: &1.waiting_edges ++ [spec]})
  end

  @doc false
  # The writes that record `node` finishing, for every join it is upstream of.
  @spec join_writes(t(), Graph.node_name()) :: [map()]
  def join_writes(%__MODULE__{waiting_edges: waiting_edges}, node) do
    node = N.normalize_node(node)

    for %WaitingEdgeSpec{channel: channel, upstream: upstream} <- waiting_edges,
        node in upstream,
        do: %{channel => node}
  end

  @doc false
  @spec put_branch_routes(t(), Graph.node_name(), function(), map() | keyword()) :: t()
  def put_branch_routes(%__MODULE__{} = graph, source, router, path_map \\ %{}) do
    source = N.normalize_node(source)

    spec = %BranchSpec{
      source: source,
      router: router,
      path_map: Map.new(path_map, fn {key, value} -> {key, N.normalize_node(value)} end)
    }

    graph
    |> maybe_record_duplicate(:branch, source, Map.has_key?(graph.conditional_edges, source))
    |> then(&%{&1 | conditional_edges: Map.put(&1.conditional_edges, source, spec)})
  end

  @spec add_reducer(t(), atom() | String.t(), function()) :: t()
  def add_reducer(%__MODULE__{} = graph, key, reducer) when is_function(reducer, 2) do
    key = N.state_key(key)

    %{
      graph
      | reducers: Map.put(graph.reducers, key, reducer),
        channels: Map.put_new(graph.channels, key, BinaryOperatorAggregate.new(reducer, key: key))
    }
  end

  @spec add_channel(t(), atom() | String.t(), term(), keyword()) :: t()
  def add_channel(%__MODULE__{} = graph, key, channel, opts) do
    key = N.state_key(key)

    subscribers =
      N.normalize_subscribers(Keyword.get(opts, :subscribers, Keyword.get(opts, :subscriber, [])))

    %{
      graph
      | channels: Map.put(graph.channels, key, N.normalize_channel(channel, key, opts)),
        channel_visibility:
          Map.put(
            graph.channel_visibility,
            key,
            N.normalize_visibility(Keyword.get(opts, :visibility, :public))
          ),
        channel_subscriptions:
          N.merge_channel_subscriptions(graph.channel_subscriptions, %{
            to_string(key) => subscribers
          })
    }
  end

  defp put_edge(graph, start_node, end_node)
       when start_node in ["__start__", "__end__"] or end_node == "__end__",
       do: graph

  defp put_edge(graph, start_node, end_node) do
    edges = Map.update(graph.edges, start_node, [end_node], &Enum.uniq(&1 ++ [end_node]))
    %{graph | edges: edges}
  end

  defp add_guarded_edge(graph, start_node, end_node, opts) do
    start_node = N.normalize_node(start_node)
    end_node = N.normalize_node(end_node)

    spec = %GuardedEdgeSpec{
      id: to_string(Keyword.get(opts, :id, guarded_edge_id(graph, start_node, end_node))),
      source: start_node,
      target: end_node,
      match: Keyword.get(opts, :when),
      max_runs: Keyword.get(opts, :max_runs),
      default?: Keyword.get(opts, :default, false) == true
    }

    graph
    |> maybe_add_entry(start_node, end_node)
    |> maybe_add_finish(start_node, end_node)
    |> then(&%{&1 | guarded_edges: Map.update(&1.guarded_edges, start_node, [spec], fn specs -> specs ++ [spec] end)})
  end

  defp add_dependency_edges(graph, %NodeSpec{deps: []}), do: graph

  defp add_dependency_edges(graph, %NodeSpec{condition: condition}) when not is_nil(condition),
    do: graph

  defp add_dependency_edges(graph, %NodeSpec{name: node, deps: [dep]}),
    do: add_edge(graph, dep, node)

  defp add_dependency_edges(graph, %NodeSpec{name: node, deps: deps}),
    do: add_join(graph, deps, node, [])

  defp maybe_add_entry(graph, "__start__", end_node),
    do: %{graph | entry_points: Enum.uniq(graph.entry_points ++ [end_node])}

  defp maybe_add_entry(graph, _start_node, _end_node), do: graph

  defp maybe_add_finish(graph, start_node, "__end__"),
    do: %{graph | finish_points: MapSet.put(graph.finish_points, start_node)}

  defp maybe_add_finish(graph, _start_node, _end_node), do: graph

  defp maybe_record_duplicate(graph, _kind, _value, false), do: graph

  defp maybe_record_duplicate(graph, kind, value, true) do
    %{graph | diagnostics: [%{kind: kind, value: value} | graph.diagnostics]}
  end

  defp waiting_edge_id(upstream, target) do
    payload = :erlang.term_to_binary({upstream, target})
    Base.encode16(:crypto.hash(:sha256, payload), case: :lower)
  end

  defp guarded_edge_options?(opts) do
    Keyword.has_key?(opts, :when) or Keyword.has_key?(opts, :max_runs) or
      Keyword.get(opts, :default, false) == true
  end

  defp guarded_edge_id(graph, source, target) do
    index = graph.guarded_edges |> Map.get(source, []) |> length()
    payload = :erlang.term_to_binary({source, target, index})
    Base.encode16(:crypto.hash(:sha256, payload), case: :lower)
  end

  defp internal_channels do
    %{
      :__node_outputs__ => BinaryOperatorAggregate.new(&merge_node_outputs/2, key: :__node_outputs__, initial: %{}),
      :__edge_runs__ => BinaryOperatorAggregate.new(&merge_edge_runs/2, key: :__edge_runs__, initial: %{})
    }
  end

  defp merge_node_outputs(left, right), do: Map.merge(left || %{}, right || %{})

  defp merge_edge_runs(left, right) do
    Map.merge(left || %{}, right || %{}, fn _key, left_count, right_count ->
      (left_count || 0) + (right_count || 0)
    end)
  end
end
