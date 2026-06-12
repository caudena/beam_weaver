defmodule BeamWeaver.Agent.Compiler do
  @moduledoc """
  Builds graph-backed agent loops from `%BeamWeaver.Agent.Spec{}`.
  """

  alias BeamWeaver.Agent.Capabilities
  alias BeamWeaver.Agent.Compiler.Routing
  alias BeamWeaver.Agent.Middleware
  alias BeamWeaver.Agent.Nodes.Middleware, as: MiddlewareNode
  alias BeamWeaver.Agent.Schema
  alias BeamWeaver.Agent.Spec
  alias BeamWeaver.Agent.State
  alias BeamWeaver.Agent.StructuredOutput
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Graph
  alias BeamWeaver.Graph.Nodes.ToolNode
  alias BeamWeaver.Graph.Nodes.ValidationNode

  @model_node :model
  @structured_response_node :structured_response
  @validation_node :validate_tools
  @tools_node :tools

  @spec compile_graph(Spec.t()) :: BeamWeaver.Graph.StateGraph.t()
  def compile_graph(%Spec{} = spec) do
    spec = Capabilities.apply(spec)
    {:ok, middleware} = Middleware.normalize_all(spec.middleware)
    response_format = StructuredOutput.normalize(spec.response_format)
    middleware_tools = Enum.flat_map(middleware, &Middleware.tools/1)
    base_tools = normalize_declared_tools(middleware_tools ++ spec.tools)
    response_strategy = StructuredOutput.effective_strategy(response_format, spec.model, base_tools)
    separate_structured_response? = separate_structured_response?(response_strategy, base_tools)

    structured_tools =
      if separate_structured_response?,
        do: [],
        else: StructuredOutput.setup_tools(response_strategy)

    tools = normalize_declared_tools(base_tools ++ structured_tools)
    tool_node? = tools != [] or Enum.any?(middleware, &Middleware.tool_node_required?/1)

    final_response_strategy =
      if separate_structured_response?,
        do: StructuredOutput.effective_strategy(response_format, spec.model, []),
        else: nil

    state_schema =
      (response_strategy || final_response_strategy)
      |> is_nil()
      |> Kernel.not()
      |> Schema.default_state_schema()
      |> merge_middleware_state_schema(middleware)

    context_schema =
      middleware
      |> Enum.reduce(%{}, fn middleware, acc ->
        Schema.merge_schema(acc, Middleware.context_schema(middleware))
      end)
      |> Schema.merge_schema(spec.context_schema)
      |> empty_to_nil()

    graph =
      Graph.new(
        name: spec.name || inspect(spec.module),
        state_schema: state_schema,
        context_schema: context_schema,
        input_schema: spec.input_schema,
        output_schema: spec.output_schema
      )
      |> add_middleware_nodes(middleware, :before_agent)
      |> add_middleware_nodes(middleware, :before_model, model_node_opts(spec))
      |> Graph.add_node(
        @model_node,
        BeamWeaver.Agent.Nodes.Model.new(spec.model,
          model_opts: spec.model_opts,
          tools: tools,
          system_prompt: spec.system_prompt,
          middleware: middleware,
          assistant_name: spec.name,
          response_format: if(separate_structured_response?, do: nil, else: response_strategy)
        ),
        model_node_opts(spec)
      )
      |> maybe_add_structured_response_node(
        spec,
        middleware,
        separate_structured_response?,
        final_response_strategy
      )
      |> add_middleware_nodes(middleware, :after_model)
      |> add_validation_node(tools, spec, tool_node?)
      |> add_tools_node(tools, middleware, tool_node?, spec)
      |> add_middleware_nodes(middleware, :after_agent)

    graph
    |> connect_entry(middleware)
    |> connect_before_agent(middleware)
    |> connect_before_model(middleware)
    |> connect_after_model(middleware, tool_node?, separate_structured_response?)
    |> connect_validation(middleware, tool_node?)
    |> connect_tools(middleware, tool_node?)
    |> connect_structured_response(middleware, separate_structured_response?)
    |> connect_after_agent(middleware)
  end

  @spec compile_opts(Spec.t(), keyword()) :: keyword()
  def compile_opts(%Spec{} = spec, opts) do
    [
      checkpointer: Keyword.get(opts, :checkpointer, spec.checkpointer),
      store: Keyword.get(opts, :store, spec.store),
      cache: Keyword.get(opts, :cache, spec.cache),
      interrupt_before: Keyword.get(opts, :interrupt_before, spec.interrupt_before || []),
      interrupt_after: Keyword.get(opts, :interrupt_after, spec.interrupt_after || []),
      debug: Keyword.get(opts, :debug, spec.debug || false),
      name: Keyword.get(opts, :name, spec.name || inspect(spec.module))
    ]
  end

  @spec run_opts(Spec.t(), keyword()) :: keyword()
  def run_opts(%Spec{} = spec, opts) do
    if Keyword.has_key?(opts, :recursion_limit) or is_nil(spec.recursion_limit) do
      opts
    else
      Keyword.put(opts, :recursion_limit, spec.recursion_limit)
    end
  end

  @spec validate_runtime!(Spec.t(), keyword()) :: :ok | {:error, Error.t()}
  def validate_runtime!(%Spec{} = spec, opts) do
    with {:ok, middleware} <- Middleware.normalize_all(spec.middleware || []) do
      with :ok <- validate_required_checkpointer(middleware, spec, opts) do
        middleware
        |> middleware_context_schema()
        |> Schema.merge_schema(spec.context_schema)
        |> Schema.validate_context(Keyword.get(opts, :context))
      end
    end
  end

  defp validate_required_checkpointer(middleware, %Spec{} = spec, opts) do
    checkpointer = Keyword.get(opts, :checkpointer, spec.checkpointer)

    if Enum.any?(middleware, &Middleware.requires_checkpointer?/1) and is_nil(checkpointer) do
      {:error,
       Error.new(:missing_checkpointer, "agent middleware requires a checkpointer", %{
         middleware:
           middleware
           |> Enum.filter(&Middleware.requires_checkpointer?/1)
           |> Enum.map(&Middleware.name/1)
       })}
    else
      :ok
    end
  end

  def model_router(state) do
    Routing.model_router(state)
  end

  def tools_router(state) do
    Routing.tools_router(state)
  end

  def validation_router(state) do
    Routing.validation_router(state)
  end

  def final_response_model_router(state) do
    case State.jump_to(state) do
      :end ->
        :end

      _other ->
        case Routing.model_router(state) do
          :end ->
            if State.structured_response?(state), do: :end, else: :structured_response

          route ->
            route
        end
    end
  end

  def structured_response_router(state) do
    case State.jump_to(state) do
      :end -> :end
      _other -> if State.structured_response?(state), do: :end, else: :structured_response
    end
  end

  def middleware_router(state, default) do
    Routing.middleware_router(state, default)
  end

  defp add_middleware_nodes(graph, middleware, hook, node_opts \\ []) do
    middleware
    |> Enum.filter(&Middleware.hook?(&1, hook))
    |> Enum.reduce(graph, fn middleware, graph ->
      Graph.add_node(
        graph,
        middleware_node_name(middleware, hook),
        MiddlewareNode.new(middleware, hook),
        node_opts
      )
    end)
  end

  defp model_node_opts(%Spec{model_opts: model_opts} = spec) do
    case Keyword.fetch(model_opts, :timeout) do
      {:ok, timeout} ->
        [timeout: timeout]

      :error ->
        case fetch_model_timeout(spec.model) do
          {:ok, timeout} -> [timeout: timeout]
          :error -> []
        end
    end
  end

  defp fetch_model_timeout(%{timeout: timeout}), do: {:ok, timeout}
  defp fetch_model_timeout(_model), do: :error

  defp add_tools_node(graph, [], middleware, tool_node?, spec) do
    if tool_node? or Enum.any?(middleware, &Middleware.hook?(&1, :wrap_tool_call)) do
      tool_node_opts = tool_node_opts(spec)

      Graph.add_node(
        graph,
        @tools_node,
        ToolNode.new([], Keyword.merge([wrap_tool_call: middleware], tool_node_opts)),
        tool_node_opts
      )
    else
      graph
    end
  end

  defp add_tools_node(graph, tools, middleware, _tool_node?, spec) do
    tool_node_opts = tool_node_opts(spec)

    Graph.add_node(
      graph,
      @tools_node,
      ToolNode.new(tools, Keyword.merge([wrap_tool_call: middleware], tool_node_opts)),
      tool_node_opts
    )
  end

  defp tool_node_opts(%Spec{model_opts: model_opts}) do
    [timeout: Keyword.get(model_opts, :tool_timeout, :infinity)]
  end

  defp add_validation_node(graph, tools, %Spec{validate_tools: true}, true) do
    Graph.add_node(graph, @validation_node, ValidationNode.new(tools, success: :silent))
  end

  defp add_validation_node(graph, _tools, _spec, _tool_node?), do: graph

  defp maybe_add_structured_response_node(
         graph,
         %Spec{} = spec,
         middleware,
         true,
         final_response_strategy
       ) do
    Graph.add_node(
      graph,
      @structured_response_node,
      BeamWeaver.Agent.Nodes.Model.new(spec.model,
        model_opts: spec.model_opts,
        tools: [],
        system_prompt: spec.system_prompt,
        middleware: final_response_middleware(middleware),
        assistant_name: spec.name,
        response_format: final_response_strategy
      ),
      model_node_opts(spec)
    )
  end

  defp maybe_add_structured_response_node(graph, _spec, _middleware, _separate?, _strategy), do: graph

  defp connect_entry(graph, middleware) do
    Graph.add_edge(
      graph,
      Graph.start(),
      first_node(middleware, :before_agent) || first_node(middleware, :before_model) ||
        @model_node
    )
  end

  defp connect_before_agent(graph, middleware) do
    chain_hooks(
      graph,
      middleware,
      :before_agent,
      first_node(middleware, :before_model) || @model_node
    )
  end

  defp connect_before_model(graph, middleware) do
    chain_hooks(graph, middleware, :before_model, @model_node)
  end

  defp connect_after_model(graph, middleware, tool_node?, structured_response_node?) do
    after_model = hook_nodes(middleware, :after_model)
    router_source = List.first(after_model) || @model_node
    exit = first_node(Enum.reverse(middleware), :after_agent) || Graph.end_node()

    graph =
      case after_model do
        [] ->
          graph

        nodes ->
          [first | rest] = Enum.reverse(nodes)

          graph =
            Graph.add_edge(graph, @model_node, first)

          rest
          |> Enum.reduce({graph, first}, fn node, {graph, previous} ->
            {Graph.add_edge(graph, previous, node), node}
          end)
          |> elem(0)
      end

    path_map =
      if tool_node? do
        %{
          model: first_node(middleware, :before_model) || @model_node,
          tools: tools_entry_node(graph),
          end: exit
        }
      else
        %{model: first_node(middleware, :before_model) || @model_node, end: exit}
      end
      |> maybe_put_structured_response_route(structured_response_node?)

    router =
      if structured_response_node?,
        do: &__MODULE__.final_response_model_router/1,
        else: &__MODULE__.model_router/1

    BeamWeaver.Graph.StateGraph.put_branch_routes(
      graph,
      router_source,
      router,
      path_map
    )
  end

  defp connect_validation(graph, middleware, tool_node?) do
    if tool_node? and Map.has_key?(graph.nodes, to_string(@validation_node)) do
      BeamWeaver.Graph.StateGraph.put_branch_routes(
        graph,
        @validation_node,
        &__MODULE__.validation_router/1,
        %{
          model: first_node(middleware, :before_model) || @model_node,
          tools: @tools_node,
          end: first_node(Enum.reverse(middleware), :after_agent) || Graph.end_node()
        }
      )
    else
      graph
    end
  end

  defp connect_tools(graph, _middleware, false), do: graph

  defp connect_tools(graph, middleware, true) do
    BeamWeaver.Graph.StateGraph.put_branch_routes(
      graph,
      @tools_node,
      &__MODULE__.tools_router/1,
      %{
        model: first_node(middleware, :before_model) || @model_node,
        end: first_node(Enum.reverse(middleware), :after_agent) || Graph.end_node()
      }
    )
  end

  defp connect_structured_response(graph, _middleware, false), do: graph

  defp connect_structured_response(graph, middleware, true) do
    exit = first_node(Enum.reverse(middleware), :after_agent) || Graph.end_node()

    BeamWeaver.Graph.StateGraph.put_branch_routes(
      graph,
      @structured_response_node,
      &__MODULE__.structured_response_router/1,
      %{
        structured_response: @structured_response_node,
        end: exit
      }
    )
  end

  defp connect_after_agent(graph, middleware) do
    nodes = hook_nodes(middleware, :after_agent)

    case Enum.reverse(nodes) do
      [] ->
        graph

      [last] ->
        Graph.add_edge(graph, last, Graph.end_node())

      [last | rest] ->
        {graph, _previous} =
          Enum.reduce(rest, {graph, last}, fn node, {graph, previous} ->
            {Graph.add_edge(graph, previous, node), node}
          end)

        Graph.add_edge(graph, List.last(rest), Graph.end_node())
    end
  end

  defp chain_hooks(graph, middleware, hook, destination) do
    nodes = hook_nodes(middleware, hook)

    case nodes do
      [] ->
        graph

      [only] ->
        add_middleware_edge(graph, only, destination)

      [first | rest] ->
        {graph, previous} =
          Enum.reduce(rest, {graph, first}, fn node, {graph, previous} ->
            {add_middleware_edge(graph, previous, node), node}
          end)

        add_middleware_edge(graph, previous, destination)
    end
  end

  defp add_middleware_edge(graph, source, destination) do
    path_map =
      %{model: @model_node, end: Graph.end_node()}
      |> Map.put(destination, destination)
      |> maybe_put_tools_route(graph)

    BeamWeaver.Graph.StateGraph.put_branch_routes(
      graph,
      source,
      fn state -> middleware_router(state, destination) end,
      path_map
    )
  end

  defp maybe_put_tools_route(path_map, graph) do
    if Map.has_key?(graph.nodes, to_string(@tools_node)) do
      Map.put(path_map, :tools, tools_entry_node(graph))
    else
      path_map
    end
  end

  defp maybe_put_structured_response_route(path_map, true),
    do: Map.put(path_map, :structured_response, @structured_response_node)

  defp maybe_put_structured_response_route(path_map, false), do: path_map

  defp tools_entry_node(graph) do
    if Map.has_key?(graph.nodes, to_string(@validation_node)) do
      @validation_node
    else
      @tools_node
    end
  end

  defp first_node(middleware, hook), do: middleware |> hook_nodes(hook) |> List.first()

  defp hook_nodes(middleware, hook) do
    middleware
    |> Enum.filter(&Middleware.hook?(&1, hook))
    |> Enum.map(&middleware_node_name(&1, hook))
  end

  defp middleware_node_name(middleware, hook), do: :"#{Middleware.name(middleware)}.#{hook}"

  defp merge_middleware_state_schema(schema, middleware) do
    Enum.reduce(middleware, schema, fn middleware, acc ->
      Schema.merge_schema(acc, Middleware.state_schema(middleware))
    end)
  end

  defp middleware_context_schema(middleware) do
    Enum.reduce(middleware, %{}, fn middleware, acc ->
      Schema.merge_schema(acc, Middleware.context_schema(middleware))
    end)
  end

  defp empty_to_nil(map) when map in [%{}, nil], do: nil
  defp empty_to_nil(map), do: map

  defp normalize_declared_tools(tools) do
    tools
    |> List.wrap()
    |> Enum.map(fn
      {tool, opts} when is_list(opts) ->
        tool

      tool ->
        tool
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(&Tool.name/1)
  end

  defp separate_structured_response?(nil, _base_tools), do: false
  defp separate_structured_response?(_strategy, []), do: false
  defp separate_structured_response?(_strategy, _base_tools), do: true

  defp final_response_middleware(middleware) do
    Enum.filter(middleware, fn middleware ->
      Middleware.name(middleware) in [
        :structured_output_retry,
        :model_retry,
        :deepagents_overflow_clip
      ]
    end)
  end
end
