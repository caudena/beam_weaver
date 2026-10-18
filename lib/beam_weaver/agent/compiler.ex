defmodule BeamWeaver.Agent.Compiler do
  @moduledoc false

  alias BeamWeaver.Agent.Capabilities
  alias BeamWeaver.Agent.Compiler.Routing
  alias BeamWeaver.Agent.Middleware
  alias BeamWeaver.Agent.Middleware.HumanInTheLoop
  alias BeamWeaver.Agent.Middleware.OverflowRecovery
  alias BeamWeaver.Agent.Middleware.PII
  alias BeamWeaver.Agent.Middleware.Subagents
  alias BeamWeaver.Agent.Middleware.ToolSelection
  alias BeamWeaver.Agent.Nodes.Middleware, as: MiddlewareNode
  alias BeamWeaver.Agent.Schema
  alias BeamWeaver.Agent.Spec
  alias BeamWeaver.Agent.State
  alias BeamWeaver.Agent.StructuredOutput
  alias BeamWeaver.Agent.StructuredOutput.AutoStrategy
  alias BeamWeaver.Agent.StructuredOutput.ProviderStrategy
  alias BeamWeaver.Agent.StructuredOutput.ToolStrategy
  alias BeamWeaver.Agent.Subagent.Compiled
  alias BeamWeaver.Agent.Subagent.Spec, as: SubagentSpec
  alias BeamWeaver.Agent.ToolNode
  alias BeamWeaver.Agent.ValidationNode
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Graph
  alias BeamWeaver.Graph.ChannelSpec
  alias BeamWeaver.Graph.Execution.ChannelLookup
  alias BeamWeaver.Graph.StateGraph
  alias BeamWeaver.MapShape

  @model_node :model
  @structured_response_node :structured_response
  @validation_node :validate_tools
  @tools_node :tools
  @structured_response_instruction "Give your final answer now, in the required format."

  # The graph of an agent module's `graph/0`: applies the capabilities to the
  # module's declarations, then compiles them.
  @spec module_graph(Spec.t()) :: BeamWeaver.Graph.StateGraph.t()
  def module_graph(%Spec{} = spec) do
    with {:ok, spec} <- Capabilities.apply(spec),
         :ok <- validate_module(spec) do
      compile_graph(spec)
    else
      {:error, %Error{} = error} -> raise ArgumentError, error.message
    end
  end

  # Builds the agent loop from a spec that `Capabilities.apply/1` returned.
  @spec compile_graph(Spec.t()) :: BeamWeaver.Graph.StateGraph.t()
  def compile_graph(%Spec{} = spec) do
    middleware = raise_on_error(Middleware.normalize_all(spec.middleware))
    response_format = StructuredOutput.normalize(spec.response_format)
    structured_output? = not is_nil(response_format)
    state_schema = merge_middleware_state_schema(Schema.default_state_schema(structured_output?), middleware)
    middleware = Subagents.bind_private_keys(middleware, schema_private_keys(state_schema))
    middleware_tools = Enum.flat_map(middleware, &Middleware.tools/1)
    base_tools = unique_tools(middleware_tools ++ raise_on_error(declared_tools(spec.tools)))
    response_strategy = StructuredOutput.effective_strategy(response_format, spec.model, base_tools)
    separate_structured_response? = separate_structured_response?(response_strategy, base_tools, spec.model)

    structured_tools =
      if separate_structured_response?,
        do: [],
        else: StructuredOutput.setup_tools(response_strategy)

    tools = unique_tools(base_tools ++ structured_tools)
    registered_tools = registered_tools(tools, middleware)
    middleware = HumanInTheLoop.bind_tools(middleware, registered_tools)
    step_costs = step_costs(middleware, spec, separate_structured_response?)

    context_schema =
      middleware |> middleware_context_schema() |> Schema.merge_schema(spec.context_schema) |> MapShape.empty_to_nil()

    graph =
      Graph.new(
        name: spec.name,
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
          response_format: if(separate_structured_response?, do: nil, else: response_strategy),
          structured_output: structured_output?,
          step_costs: step_costs
        ),
        model_node_opts(spec)
      )
      |> maybe_add_structured_response_node(
        spec,
        middleware,
        separate_structured_response?,
        response_format,
        step_costs
      )
      |> add_middleware_nodes(middleware, :after_model)
      |> add_validation_node(registered_tools, spec)
      |> add_tools_node(registered_tools, middleware, spec)
      |> add_middleware_nodes(middleware, :after_agent)

    graph
    |> connect_entry(middleware)
    |> connect_before_agent(middleware)
    |> connect_before_model(middleware)
    |> connect_after_model(middleware, separate_structured_response?)
    |> connect_validation(middleware)
    |> connect_tools(middleware)
    |> connect_structured_response(middleware, separate_structured_response?)
    |> connect_after_agent(middleware)
  end

  # Call options that change the compiled graph rather than the run.
  @graph_opts [:checkpointer, :store, :cache, :interrupt_before, :interrupt_after]

  @spec graph_opts?(keyword()) :: boolean()
  def graph_opts?(opts), do: Enum.any?(@graph_opts, &Keyword.has_key?(opts, &1))

  @spec compile_opts(Spec.t(), keyword()) :: keyword()
  def compile_opts(%Spec{} = spec, opts) do
    [
      checkpointer: Keyword.get(opts, :checkpointer, spec.checkpointer),
      store: Keyword.get(opts, :store, spec.store),
      cache: Keyword.get(opts, :cache, spec.cache),
      interrupt_before: Keyword.get(opts, :interrupt_before, spec.interrupt_before),
      interrupt_after: Keyword.get(opts, :interrupt_after, spec.interrupt_after),
      step_timeout: Keyword.get(opts, :step_timeout, spec.step_timeout || :infinity),
      run_timeout: Keyword.get(opts, :run_timeout, spec.run_timeout || :infinity),
      name: Keyword.get(opts, :name, spec.name)
    ]
  end

  # Checks the declarations that can only be checked once they are evaluated:
  # the middleware, the tools, the response format and every subagent, as
  # each `task` call would build it, without compiling the subagents' graphs.
  # `opts[:visited]` lists the agent modules being checked, so agents that
  # name each other as subagents are checked once.
  @spec validate(Spec.t(), keyword()) :: :ok | {:error, Error.t()}
  def validate(%Spec{} = spec, opts) do
    with {:ok, middleware} <- Middleware.normalize_all(spec.middleware),
         {:ok, tools} <- declared_tools(spec.tools),
         :ok <- validate_tools(tools),
         :ok <- validate_response_format(spec.response_format) do
      validate_subagents(middleware, opts)
    end
  end

  # `validate/2` for an agent module, whose declarations are evaluated on
  # every call: the check passes once per version of the module, and later
  # calls skip it. Takes the module, or its spec after `Capabilities.apply/1`.
  @spec validate_module(module() | Spec.t(), keyword()) :: :ok | {:error, Error.t()}
  def validate_module(module_or_spec, opts \\ [])

  def validate_module(%Spec{module: module} = spec, opts) do
    validate_module_once(module, opts, fn opts -> validate(spec, opts) end)
  end

  def validate_module(module, opts) when is_atom(module) do
    validate_module_once(module, opts, fn opts ->
      with {:ok, spec} <- Capabilities.apply(module.__beam_weaver_agent_spec__()), do: validate(spec, opts)
    end)
  end

  defp validate_module_once(module, opts, validate) do
    key = {__MODULE__, :validated, module, module.module_info(:md5)}
    visited = Keyword.get(opts, :visited, [])

    if module in visited or :persistent_term.get(key, false) do
      :ok
    else
      with :ok <- validate.(Keyword.put(opts, :visited, [module | visited])), do: :persistent_term.put(key, true)
    end
  end

  defp validate_tools(tools) do
    case Enum.reject(tools, &tool?/1) do
      [] ->
        :ok

      [tool | _rest] ->
        {:error,
         Error.new(
           :invalid_tool,
           "#{inspect(tool)} is not a tool: list modules that `use BeamWeaver.Tool`, tool structs or toolkits",
           %{tool: inspect(tool)}
         )}
    end
  end

  defp tool?(%Tool{}), do: true
  defp tool?(%module{}), do: Tool.implemented_by?(module)
  defp tool?(module) when is_atom(module), do: Tool.implemented_by?(module)
  defp tool?(_tool), do: false

  defp validate_response_format(nil), do: :ok

  defp validate_response_format(%strategy{schema: schema})
       when strategy in [AutoStrategy, ToolStrategy, ProviderStrategy],
       do: validate_response_schema(schema)

  defp validate_response_format(schema), do: validate_response_schema(schema)

  defp validate_response_schema(%{"oneOf" => variants}) when is_list(variants), do: validate_schema_variants(variants)
  defp validate_response_schema(%{oneOf: variants}) when is_list(variants), do: validate_schema_variants(variants)
  defp validate_response_schema(schema) when is_map(schema), do: :ok

  defp validate_response_schema(module) when is_atom(module) and module not in [nil, true, false] do
    cond do
      not Code.ensure_loaded?(module) ->
        invalid_response_format(module, "response_format #{inspect(module)} is not a module")

      is_nil(BeamWeaver.Schema.module_schema(module)) ->
        invalid_response_format(
          module,
          "response_format #{inspect(module)} declares no schema: `use BeamWeaver.Schema` in it, or define `json_schema/0`"
        )

      true ->
        :ok
    end
  end

  defp validate_response_schema(other) do
    invalid_response_format(
      other,
      "response_format must be a schema module, a JSON schema map or a BeamWeaver.Agent.StructuredOutput strategy"
    )
  end

  defp validate_schema_variants(variants),
    do: Enum.find_value(variants, :ok, fn variant -> with :ok <- validate_response_schema(variant), do: nil end)

  defp invalid_response_format(value, message),
    do: {:error, Error.new(:invalid_agent, message, %{response_format: inspect(value)})}

  # A subagent read from an agent module is checked once per module and
  # options, as agent modules are, so that agents that name each other, or
  # themselves, as subagents are checked once each.
  defp validate_subagents(middleware, opts) do
    Enum.find_value(middleware, :ok, fn
      %Subagents{subagents: subagents} = subagents_middleware ->
        visited = Keyword.get(opts, :visited, [])
        unchecked = Enum.reject(subagents, &(subagent_source(&1) in visited))
        sources = for subagent <- unchecked, source = subagent_source(subagent), do: source

        with :ok <-
               Subagents.validate(
                 %{subagents_middleware | subagents: unchecked},
                 Keyword.put(opts, :visited, sources ++ visited)
               ),
             do: nil

      _middleware ->
        nil
    end)
  end

  defp subagent_source(%Compiled{agent: %SubagentSpec{source: source}}), do: source
  defp subagent_source(_subagent), do: nil

  # Checks a call against the agent and returns the options to run it with:
  # the agent's recursion limit unless the call sets one, and the context with
  # its declared fields under their atom keys.
  @spec run_opts(Spec.t(), keyword()) :: {:ok, keyword()} | {:error, Error.t()}
  def run_opts(%Spec{} = spec, opts) do
    with {:ok, middleware} <- Middleware.normalize_all(spec.middleware),
         {:ok, _tools} <- declared_tools(spec.tools),
         :ok <- validate_required_checkpointer(middleware, spec, opts),
         {:ok, context} <-
           middleware
           |> middleware_context_schema()
           |> Schema.merge_schema(spec.context_schema)
           |> Schema.normalize_context(Keyword.get(opts, :context)) do
      opts = if is_nil(context), do: opts, else: Keyword.put(opts, :context, context)

      opts =
        if is_nil(spec.recursion_limit), do: opts, else: Keyword.put_new(opts, :recursion_limit, spec.recursion_limit)

      {:ok, opts}
    end
  end

  defp validate_required_checkpointer(middleware, %Spec{} = spec, opts) do
    requiring = Enum.filter(middleware, &Middleware.requires_checkpointer?/1)

    if requiring != [] and is_nil(Keyword.get(opts, :checkpointer, spec.checkpointer)) do
      {:error,
       Error.new(:missing_checkpointer, "agent middleware requires a checkpointer", %{
         middleware: Enum.map(requiring, &Middleware.name/1)
       })}
    else
      :ok
    end
  end

  defp final_response_model_router(state),
    do: with(:end <- Routing.model_router(state), do: structured_response_router(state))

  defp structured_response_router(state) do
    if State.jump_to(state) == :end or State.structured_response?(state), do: :end, else: :structured_response
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

  defp model_node_opts(%Spec{model_opts: model_opts, model: model}) do
    case Keyword.fetch(model_opts, :timeout) do
      {:ok, timeout} -> [timeout: timeout]
      :error when is_map_key(model, :timeout) -> [timeout: model.timeout]
      :error -> []
    end
  end

  # The tools node is always there: a model that asks for a tool the agent
  # doesn't have gets an error message back, as for any unknown tool.
  # `tool_timeout` limits each tool call, so a slow call becomes an error
  # message too; the node itself has no limit, since tools that can't run
  # concurrently run one after another. Tools get the state without the
  # agent's private and managed keys.
  defp add_tools_node(graph, tools, middleware, spec) do
    tool_node =
      ToolNode.new(tools,
        wrap_tool_call: middleware,
        timeout: spec.tool_timeout || :infinity,
        private_keys: private_keys(graph)
      )

    Graph.add_node(graph, @tools_node, tool_node, timeout: :infinity)
  end

  # The tools the tools node can run: the agent's tools and the ones a
  # `ToolSelection` lists, which it adds to the model's calls. Each run offers
  # the model some of them, and the tools node runs only those; a run that
  # continues from a checkpoint finds them here by name.
  defp registered_tools(tools, middleware) do
    selection_tools =
      Enum.flat_map(middleware, fn
        %ToolSelection{tools: listed} when is_list(listed) -> Enum.reject(listed, &is_nil/1)
        _middleware -> []
      end)

    unique_tools(tools ++ selection_tools)
  end

  # The keys a state schema declares private or managed, before there is a
  # graph to ask.
  defp schema_private_keys(state_schema) do
    for {key, %ChannelSpec{visibility: visibility}} <- state_schema,
        visibility in [:private, :private_checkpointed],
        do: to_string(key)
  end

  defp private_keys(%StateGraph{} = graph) do
    for key <- Map.keys(graph.channel_visibility) ++ Map.keys(graph.managed),
        ChannelLookup.private_channel?(graph, key) or ChannelLookup.managed_key?(graph, key),
        do: key
  end

  defp add_validation_node(graph, tools, %Spec{validate_tools: true}) do
    Graph.add_node(graph, @validation_node, ValidationNode.new(tools, success: :silent))
  end

  defp add_validation_node(graph, _tools, _spec), do: graph

  defp maybe_add_structured_response_node(graph, %Spec{} = spec, middleware, true, response_format, step_costs) do
    Graph.add_node(
      graph,
      @structured_response_node,
      BeamWeaver.Agent.Nodes.Model.new(spec.model,
        model_opts: spec.model_opts,
        tools: [],
        system_prompt: spec.system_prompt,
        middleware: final_response_middleware(middleware),
        assistant_name: spec.name,
        response_format: StructuredOutput.effective_strategy(response_format, spec.model, []),
        final_instruction: @structured_response_instruction,
        step_costs: step_costs,
        save_tool_set: false,
        structured_output: true
      ),
      model_node_opts(spec)
    )
  end

  defp maybe_add_structured_response_node(graph, _spec, _middleware, _separate?, _strategy, _step_costs),
    do: graph

  # How many steps after a model step its tool calls need: `:tool_round` to
  # run the tools, call the model again and still finish the run, and
  # `:return_direct` to run tools that end the run. The middleware hooks and
  # the validation and structured-response nodes on the way each take one.
  defp step_costs(middleware, %Spec{} = spec, separate_structured_response?) do
    after_model = length(hook_nodes(middleware, :after_model))
    before_model = length(hook_nodes(middleware, :before_model))
    after_agent = length(hook_nodes(middleware, :after_agent))
    validation = if spec.validate_tools == true, do: 1, else: 0
    structured_response = if separate_structured_response?, do: 1, else: 0

    to_tools = after_model + validation + 1
    finish = after_model + structured_response + after_agent

    %{
      tool_round: to_tools + before_model + 1 + finish,
      return_direct: to_tools + after_agent
    }
  end

  defp connect_entry(graph, middleware),
    do: Graph.add_edge(graph, Graph.start(), first_node(middleware, :before_agent) || model_entry(middleware))

  defp connect_before_agent(graph, middleware),
    do: chain_hooks(graph, middleware, :before_agent, model_entry(middleware))

  defp connect_before_model(graph, middleware) do
    chain_hooks(graph, middleware, :before_model, @model_node)
  end

  # The `after_model` hooks run last middleware first. A hook's jump to the
  # model or the end (a halt) skips the hooks after it, as in the other hook
  # chains: the jump lasts one step, so a later hook's node couldn't pass it
  # on. The last hook routes the model's answer.
  defp connect_after_model(graph, middleware, structured_response_node?) do
    after_model = hook_nodes(middleware, :after_model)
    router_source = List.first(after_model) || @model_node
    jumps = %{model: model_entry(middleware), tools: tools_entry_node(graph), end: exit_node(middleware)}

    graph =
      case Enum.reverse(after_model) do
        [] ->
          graph

        [first | _rest] = chain ->
          chain
          |> Enum.chunk_every(2, 1, :discard)
          |> Enum.reduce(Graph.add_edge(graph, @model_node, first), fn [previous, node], graph ->
            add_after_model_edge(graph, previous, node, jumps)
          end)
      end

    {router, path_map} =
      if structured_response_node?,
        do: {&final_response_model_router/1, Map.put(jumps, :structured_response, @structured_response_node)},
        else: {&Routing.model_router/1, jumps}

    BeamWeaver.Graph.StateGraph.put_branch_routes(
      graph,
      router_source,
      to_tools(graph, router, middleware),
      path_map
    )
  end

  defp connect_validation(graph, middleware) do
    if Map.has_key?(graph.nodes, to_string(@validation_node)) do
      BeamWeaver.Graph.StateGraph.put_branch_routes(
        graph,
        @validation_node,
        if(per_call_review?(middleware),
          do: Routing.sending_tool_calls(&Routing.validation_router/1),
          else: &Routing.validation_router/1
        ),
        %{model: model_entry(middleware), tools: @tools_node, end: exit_node(middleware)}
      )
    else
      graph
    end
  end

  defp connect_tools(graph, middleware) do
    BeamWeaver.Graph.StateGraph.put_branch_routes(
      graph,
      @tools_node,
      &Routing.tools_router/1,
      %{model: model_entry(middleware), end: exit_node(middleware)}
    )
  end

  defp connect_structured_response(graph, _middleware, false), do: graph

  defp connect_structured_response(graph, middleware, true) do
    BeamWeaver.Graph.StateGraph.put_branch_routes(
      graph,
      @structured_response_node,
      &structured_response_router/1,
      %{structured_response: @structured_response_node, end: exit_node(middleware)}
    )
  end

  defp connect_after_agent(graph, middleware) do
    (Enum.reverse(hook_nodes(middleware, :after_agent)) ++ [Graph.end_node()])
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.reduce(graph, fn [source, next], graph -> Graph.add_edge(graph, source, next) end)
  end

  defp chain_hooks(graph, middleware, hook, destination) do
    (hook_nodes(middleware, hook) ++ [destination])
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.reduce(graph, fn [source, next], graph -> add_middleware_edge(graph, source, next, middleware) end)
  end

  defp add_after_model_edge(graph, source, next, jumps) do
    BeamWeaver.Graph.StateGraph.put_branch_routes(
      graph,
      source,
      fn state -> Routing.after_model_router(state, next) end,
      jumps |> Map.take([:model, :end]) |> Map.put(next, next)
    )
  end

  defp add_middleware_edge(graph, source, destination, middleware) do
    path_map =
      %{model: @model_node, tools: tools_entry_node(graph), end: Graph.end_node()}
      |> Map.put(destination, destination)

    BeamWeaver.Graph.StateGraph.put_branch_routes(
      graph,
      source,
      to_tools(graph, &Routing.middleware_router(&1, destination), middleware),
      path_map
    )
  end

  # In per-call review, a route that reaches the tools node directly sends it
  # each pending call as a task of its own; the validation node, when there
  # is one, sends them after it has checked them.
  defp to_tools(graph, router, middleware) do
    if per_call_review?(middleware) and tools_entry_node(graph) == @tools_node,
      do: Routing.sending_tool_calls(router),
      else: router
  end

  defp per_call_review?(middleware),
    do: Enum.any?(middleware, &match?(%HumanInTheLoop{interrupt_mode: :per_call}, &1))

  defp tools_entry_node(graph) do
    if Map.has_key?(graph.nodes, to_string(@validation_node)) do
      @validation_node
    else
      @tools_node
    end
  end

  defp first_node(middleware, hook), do: middleware |> hook_nodes(hook) |> List.first()
  defp model_entry(middleware), do: first_node(middleware, :before_model) || @model_node
  defp exit_node(middleware), do: first_node(Enum.reverse(middleware), :after_agent) || Graph.end_node()

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

  # The declared tools with every toolkit replaced by the tools it returns.
  # Only a toolkit takes options, as `{toolkit, opts}`; they go to its
  # `tools/1`.
  @spec declared_tools(term()) :: {:ok, [term()]} | {:error, Error.t()}
  defp declared_tools(tools) do
    tools
    |> List.wrap()
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      case expand_tool(entry) do
        {:ok, expanded} -> {:cont, {:ok, acc ++ expanded}}
        {:error, %Error{}} = error -> {:halt, error}
      end
    end)
  end

  defp expand_tool({tool, opts}) when is_list(opts) do
    cond do
      toolkit?(tool) ->
        load_toolkit(tool, opts)

      opts == [] ->
        {:ok, [tool]}

      true ->
        {:error,
         Error.new(:invalid_tool, "only a toolkit takes options in tools; #{inspect(tool)} is not a toolkit", %{
           tool: inspect(tool),
           options: for({key, _value} <- opts, do: key)
         })}
    end
  end

  defp expand_tool(tool) do
    if toolkit?(tool), do: load_toolkit(tool, []), else: {:ok, [tool]}
  end

  defp toolkit?(module) when is_atom(module), do: BeamWeaver.ToolKit.implemented_by?(module)
  defp toolkit?(_tool), do: false

  defp load_toolkit(module, opts) do
    with {:ok, tools} <- BeamWeaver.ToolKit.tools(module, opts), do: declared_tools(tools)
  end

  defp unique_tools(tools), do: Enum.uniq_by(tools, &Tool.name/1)

  defp raise_on_error({:ok, value}), do: value
  defp raise_on_error({:error, %Error{} = error}), do: raise(ArgumentError, error.message)

  # A provider that accepts a response schema alongside function tools (the
  # model profile's `structured_output_with_tools`) answers the tool loop and
  # the structured output in one call: tool-call turns pass through the
  # provider strategy untouched and the final message is parsed against the
  # schema. Every other combination of tools and a structured response keeps
  # the separate structured-response call after the tool loop.
  defp separate_structured_response?(nil, _base_tools, _model), do: false
  defp separate_structured_response?(_strategy, [], _model), do: false

  defp separate_structured_response?(%BeamWeaver.Agent.StructuredOutput.ProviderStrategy{}, _base_tools, model),
    do: not BeamWeaver.Agent.StructuredOutput.Policy.structured_output_with_tools?(model)

  defp separate_structured_response?(_strategy, _base_tools, _model), do: true

  # The structured-response call repeats the whole conversation, so it keeps
  # the prompt-cache middleware: without it the call carries no cache key and
  # pays the uncached price for the context the tool loop just cached. It also
  # keeps the prompt that `DynamicPrompt` builds, the `PII` rules, whose
  # output edits apply to the structured answer like to every other reply, and
  # `UnsupportedMedia`, so a model that can't take the thread's media gets
  # notices in this call too.
  defp final_response_middleware(middleware) do
    middleware
    |> Enum.filter(fn middleware ->
      match?(%PII{}, middleware) or
        Middleware.name(middleware) in [
          "structured_output_retry",
          "typesafe_model_router",
          "model_retry",
          "deepagents_overflow_clip",
          "deepagents_prompt_caching",
          "dynamic_prompt",
          "unsupported_media"
        ]
    end)
    |> Enum.map(&clip_only/1)
  end

  # Automatic summarization isn't part of that call, so overflow recovery
  # there only clips, without the summarization the agent gave it.
  defp clip_only(%OverflowRecovery{} = recovery), do: %{recovery | summarization: nil}
  defp clip_only(middleware), do: middleware
end
