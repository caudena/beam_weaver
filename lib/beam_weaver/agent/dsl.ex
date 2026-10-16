defmodule BeamWeaver.Agent.DSL do
  @moduledoc false

  @graph_attributes [
    beam_weaver_nodes: true,
    beam_weaver_edges: true,
    beam_weaver_reducers: true,
    beam_weaver_channels: true,
    beam_weaver_joins: true
  ]

  @dsl_fields [
    name: [attr: :beam_weaver_name],
    description: [attr: :beam_weaver_description],
    checkpointer: [attr: :beam_weaver_checkpointer],
    store: [attr: :beam_weaver_store],
    cache: [attr: :beam_weaver_cache],
    model: [attr: :beam_weaver_model],
    model_options: [attr: :beam_weaver_model_options],
    model_opts: [attr: :beam_weaver_model_opts],
    tools: [attr: :beam_weaver_tools],
    validate_tools: [attr: :beam_weaver_validate_tools],
    system_prompt: [attr: :beam_weaver_system_prompt],
    middleware: [attr: :beam_weaver_middleware],
    filesystem: [attr: :beam_weaver_filesystem],
    filesystem_permissions: [attr: :beam_weaver_filesystem_permissions],
    skills: [attr: :beam_weaver_skills],
    memory: [attr: :beam_weaver_memory],
    subagents: [attr: :beam_weaver_subagents],
    async_subagents: [attr: :beam_weaver_async_subagents],
    compact_conversation: [attr: :beam_weaver_compact_conversation],
    overflow_recovery: [attr: :beam_weaver_overflow_recovery],
    prompt_caching: [attr: :beam_weaver_prompt_caching],
    exclude_tools: [attr: :beam_weaver_exclude_tools],
    tool_descriptions: [attr: :beam_weaver_tool_descriptions],
    interrupt_on: [attr: :beam_weaver_interrupt_on],
    response_format: [attr: :beam_weaver_response_format],
    context_schema: [attr: :beam_weaver_context_schema],
    input_schema: [attr: :beam_weaver_input_schema],
    output_schema: [attr: :beam_weaver_output_schema],
    context_schema_entries: [
      attr: :beam_weaver_context_schema_entries,
      accumulate: true,
      reverse: true,
      default: []
    ],
    schema_target: [attr: :beam_weaver_schema_target],
    interrupt_before: [attr: :beam_weaver_interrupt_before],
    interrupt_after: [attr: :beam_weaver_interrupt_after],
    recursion_limit: [attr: :beam_weaver_recursion_limit],
    execution_mode: [attr: :beam_weaver_execution_mode],
    capability_profile: [attr: :beam_weaver_capability_profile],
    tool_timeout: [attr: :beam_weaver_tool_timeout],
    step_timeout: [attr: :beam_weaver_step_timeout],
    run_timeout: [attr: :beam_weaver_run_timeout]
  ]

  @special_macros [
    :model,
    :model_options,
    :context_schema,
    :context_schema_entries,
    :schema_target,
    :tools,
    :middleware,
    :subagents,
    :async_subagents,
    :response_format
  ]

  @spec_quote_fields [
    {:name, nil, :ast},
    {:description, nil, :ast},
    {:model, nil, :ast},
    {:model_opts, [], :ast},
    {:tools, [], :ast},
    {:validate_tools, false, :ast},
    {:middleware, [], :ast},
    {:filesystem, nil, :ast},
    {:filesystem_permissions, nil, :ast},
    {:skills, nil, :ast},
    {:memory, nil, :ast},
    {:subagents, nil, :ast},
    {:async_subagents, nil, :ast},
    {:compact_conversation, nil, :ast},
    {:overflow_recovery, nil, :ast},
    {:prompt_caching, nil, :ast},
    {:exclude_tools, nil, :ast},
    {:tool_descriptions, nil, :ast},
    {:interrupt_on, nil, :ast},
    {:system_prompt, nil, :ast},
    {:response_format, nil, :ast},
    {:checkpointer, nil, :ast},
    {:store, nil, :ast},
    {:cache, nil, :ast},
    {:context_schema, nil, :ast},
    {:input_schema, nil, :ast},
    {:output_schema, nil, :ast},
    {:interrupt_before, [], :ast},
    {:interrupt_after, [], :ast},
    {:recursion_limit, nil, :ast},
    {:execution_mode, nil, :ast},
    {:capability_profile, nil, :ast},
    {:tool_timeout, nil, :ast},
    {:step_timeout, nil, :ast},
    {:run_timeout, nil, :ast}
  ]

  # In-memory adapters whose `new` creates ETS tables, with the declaration
  # that takes each and its database-backed counterpart.
  @in_memory_adapters %{
    BeamWeaver.Checkpoint.ETS => {:checkpointer, "saver", "BeamWeaver.Checkpoint.Ecto"},
    BeamWeaver.Memory.ETS => {:store, "store", "BeamWeaver.Memory.Ecto"},
    BeamWeaver.Cache.ETS => {:cache, "cache", "BeamWeaver.Cache.Ecto"}
  }

  # What every call loses when its declaration builds a new adapter.
  @in_memory_losses %{
    checkpointer: "every call starts its thread over and get_state/1 finds nothing",
    store: "what one call saves is gone in the next",
    cache: "nothing one call caches is found by the next"
  }

  # The declaration a collected attribute comes from, when the names differ.
  @declaration_names %{
    model_options: :model,
    context_schema_entries: :context_schema,
    interrupt_before: :interrupts,
    interrupt_after: :interrupts
  }

  def imports do
    [
      node: 2,
      node: 3,
      edge: 2,
      edge: 3,
      reducer: 2,
      graph: 1,
      tools: 1,
      middleware: 1,
      subagents: 1,
      async_subagents: 1,
      model: 1,
      model: 2,
      response_schema: 1,
      response_schema: 2,
      response_format: 1,
      context_schema: 1,
      interrupts: 1,
      field: 2,
      field: 3
    ] ++ Enum.map(simple_macro_fields(), fn {name, _attr} -> {name, 1} end)
  end

  def simple_macro_fields do
    @dsl_fields
    |> Keyword.drop(@special_macros)
    |> Enum.map(fn {name, opts} -> {name, Keyword.fetch!(opts, :attr)} end)
  end

  def register_attribute_quotes do
    graph_attribute_quotes() ++ dsl_attribute_quotes()
  end

  def collect_attrs(module) do
    Map.new(@dsl_fields, fn {name, opts} ->
      attr = Keyword.fetch!(opts, :attr)
      value = Module.get_attribute(module, attr)
      value = if Keyword.get(opts, :reverse, false), do: Enum.reverse(value || []), else: value
      {name, value || Keyword.get(opts, :default)}
    end)
  end

  defp graph_attribute_quotes do
    Enum.map(@graph_attributes, fn {attr, accumulate?} ->
      quote do
        Module.register_attribute(__MODULE__, unquote(attr), accumulate: unquote(accumulate?))
      end
    end)
  end

  defp dsl_attribute_quotes do
    Enum.map(@dsl_fields, fn {_name, opts} ->
      attr = Keyword.fetch!(opts, :attr)
      accumulate? = Keyword.get(opts, :accumulate, false)

      quote do
        Module.register_attribute(__MODULE__, unquote(attr), accumulate: unquote(accumulate?))
      end
    end)
  end

  def schema_from_entries(base, entries) do
    Enum.reduce(entries, base || %{}, fn {key, declaration}, acc ->
      Map.put(acc, key, schema_entry(declaration))
    end)
  end

  def schema_attr!(:context, :field, _caller), do: :beam_weaver_context_schema_entries

  def schema_attr!(_target, type, caller) do
    raise CompileError,
      file: caller.file,
      line: caller.line,
      description: "#{type}/2 can only be used inside context_schema blocks"
  end

  def schema_block_entries!(caller, target, block) do
    block
    |> block_expressions()
    |> Enum.map(&schema_block_entry!(caller, target, &1))
  end

  def schema_quote(nil, []), do: nil

  def schema_quote(schema_ast, entries) do
    base = schema_ast || quote(do: %{})
    entries_ast = Enum.map(entries, &schema_entry_quote/1)

    quote do
      BeamWeaver.Agent.__schema_from_entries__(unquote(base), [unquote_splicing(entries_ast)])
    end
  end

  def spec_quote(_module, attrs) when is_map(attrs) do
    attrs_ast = spec_attrs_ast(attrs)

    quote do
      @impl BeamWeaver.Agent
      def __beam_weaver_agent_spec__ do
        BeamWeaver.Agent.Spec.from_dsl_attrs(__MODULE__, unquote(attrs_ast))
      end
    end
  end

  defp spec_attrs_ast(attrs) do
    {:%{}, [], Enum.map(@spec_quote_fields, &spec_attr_entry(attrs, &1))}
  end

  defp spec_attr_entry(attrs, {field, default, mode}) do
    {field, spec_attr_value_ast(Map.get(attrs, field), default, mode)}
  end

  defp spec_attr_value_ast(nil, default, :ast), do: default
  defp spec_attr_value_ast(value, _default, :ast), do: value

  @doc false
  # The options written after `model "..."` and the ones from `model_opts`,
  # merged when the agent runs; `model_opts` wins on a shared key.
  def model_opts_quote(nil, nil), do: nil
  def model_opts_quote(model_options, nil), do: model_options
  def model_opts_quote(nil, model_opts), do: model_opts

  def model_opts_quote(model_options, model_opts) do
    quote do
      Keyword.merge(unquote(model_options), unquote(model_opts))
    end
  end

  def graph_builder_quote(
        module,
        nodes,
        edges,
        reducers,
        channels,
        joins
      ) do
    channel_quotes =
      Enum.map(channels, fn {key, merge, opts} ->
        quote do
          graph =
            BeamWeaver.Agent.__add_graph_channel__(
              graph,
              unquote(key),
              unquote(merge),
              unquote(Macro.escape(opts))
            )
        end
      end)

    node_quotes =
      Enum.map(nodes, fn {name, fun_ast, opts} ->
        quote do
          graph = BeamWeaver.Graph.add_node(graph, unquote(name), unquote(fun_ast), unquote(Macro.escape(opts)))
        end
      end)

    reducer_quotes =
      Enum.map(reducers, fn {key, reducer_ast} ->
        quote do
          graph = BeamWeaver.Graph.add_reducer(graph, unquote(key), unquote(reducer_ast))
        end
      end)

    edge_quotes =
      Enum.map(edges, fn {start_node, end_node, opts} ->
        quote do
          graph =
            BeamWeaver.Graph.add_edge(
              graph,
              unquote(start_node),
              unquote(end_node),
              unquote(Macro.escape(opts))
            )
        end
      end)

    join_quotes =
      Enum.map(joins, fn {upstream_nodes, downstream_node, opts} ->
        quote do
          graph =
            BeamWeaver.Graph.add_join(
              graph,
              unquote(upstream_nodes),
              unquote(downstream_node),
              unquote(Macro.escape(opts))
            )
        end
      end)

    quote do
      @impl BeamWeaver.Agent
      def graph do
        graph = BeamWeaver.Graph.new(name: inspect(unquote(module)))
        unquote_splicing(channel_quotes)
        unquote_splicing(reducer_quotes)
        unquote_splicing(node_quotes)
        unquote_splicing(edge_quotes)
        unquote_splicing(join_quotes)
        graph
      end
    end
  end

  def agent_compiler_graph_quote do
    quote do
      @impl BeamWeaver.Agent
      def graph do
        BeamWeaver.Agent.Compiler.module_graph(__beam_weaver_agent_spec__())
      end
    end
  end

  def validate_static_agent!(
        env,
        nodes,
        edges,
        graph_defined?,
        model_ast,
        tools_ast,
        validate_tools_ast,
        system_prompt_ast,
        middleware_ast,
        response_format_ast
      ) do
    node_names = Enum.map(nodes, fn {name, _fun, _opts} -> to_string(name) end)

    case duplicates(node_names) do
      [] ->
        :ok

      duplicate_names ->
        raise CompileError,
          file: env.file,
          line: env.line,
          description: "duplicate BeamWeaver agent node names: #{Enum.join(duplicate_names, ", ")}"
    end

    if nodes != [] and
         not Enum.any?(edges, fn {start_node, _end_node, _opts} ->
           start_node == :__start__
         end) do
      raise CompileError,
        file: env.file,
        line: env.line,
        description: "BeamWeaver agent DSL must define an edge from Graph.start()"
    end

    loop_declarations? =
      model_ast || tools_ast || validate_tools_ast || system_prompt_ast || middleware_ast ||
        response_format_ast

    if graph_defined? and loop_declarations? do
      raise CompileError,
        file: env.file,
        line: env.line,
        description: "BeamWeaver agent model/tools DSL cannot be combined with a custom graph/0"
    end

    if model_ast &&
         (nodes != [] or edges != []) do
      raise CompileError,
        file: env.file,
        line: env.line,
        description: "BeamWeaver agent model/tools DSL builds its own graph; use graph/0 for custom graph composition"
    end

    if is_nil(model_ast) and
         (tools_ast || validate_tools_ast || system_prompt_ast || response_format_ast) do
      raise CompileError,
        file: env.file,
        line: env.line,
        description: "BeamWeaver agent tools/validate_tools/system_prompt/response_format declarations require model/1"
    end
  end

  @doc false
  # Declarations are evaluated on every call, so one that builds an in-memory
  # saver, store or cache gives every call a new, empty one, and leaves its
  # ETS tables behind. Raises a `CompileError` for the first such call in a
  # declaration, outside anonymous functions, which run only when called.
  def reject_in_memory_adapters!(env, attrs, nodes) do
    declarations =
      Enum.map(attrs, fn {name, ast} -> {Map.get(@declaration_names, name, name), ast} end) ++
        Enum.map(nodes, fn {_name, fun_ast, _opts} -> {:node, fun_ast} end)

    offenders =
      for {declaration, ast} <- declarations,
          call = in_memory_adapter_call(ast, env),
          do: {declaration, call}

    case Enum.sort_by(offenders, fn {_declaration, {_module, call}} -> call_line(call, env) end) do
      [] ->
        :ok

      [{declaration, {module, call}} | _later] ->
        raise CompileError,
          file: env.file,
          line: call_line(call, env),
          description: in_memory_adapter_message(env.module, declaration, module, call)
    end
  end

  defp in_memory_adapter_call({:fn, _meta, _clauses}, _env), do: nil
  defp in_memory_adapter_call({:&, _meta, _args}, _env), do: nil

  defp in_memory_adapter_call({{:., _dot_meta, [module_ast, :new]}, _meta, args} = call, env) when is_list(args) do
    module = expand_module(module_ast, env)

    if Map.has_key?(@in_memory_adapters, module),
      do: {module, call},
      else: in_memory_adapter_call(args, env)
  end

  defp in_memory_adapter_call({form, _meta, args}, env) when is_list(args),
    do: in_memory_adapter_call(form, env) || in_memory_adapter_call(args, env)

  defp in_memory_adapter_call({left, right}, env),
    do: in_memory_adapter_call(left, env) || in_memory_adapter_call(right, env)

  defp in_memory_adapter_call(list, env) when is_list(list),
    do: Enum.find_value(list, &in_memory_adapter_call(&1, env))

  defp in_memory_adapter_call(_ast, _env), do: nil

  defp expand_module({:__aliases__, _meta, _parts} = alias_ast, env), do: Macro.expand(alias_ast, env)
  defp expand_module(module, _env) when is_atom(module), do: module
  defp expand_module(_ast, _env), do: nil

  defp call_line({_call, meta, _args}, env), do: Keyword.get(meta, :line, env.line)

  defp in_memory_adapter_message(agent, declaration, module, call) do
    {option, noun, durable} = Map.fetch!(@in_memory_adapters, module)

    {loss, keep} =
      if declaration == option do
        {Map.fetch!(@in_memory_losses, option),
         "pass it to each call with `#{option}: #{noun}`; or declare a function that returns it, " <>
           "such as `#{option} MyApp.Storage.#{option}()`"}
      else
        {"what it holds is lost after every call",
         "declare a function that returns it, such as `MyApp.Storage.#{option}()`"}
      end

    "the `#{declaration}` declaration creates a new, empty in-memory #{noun} with " <>
      "`#{Macro.to_string(call)}` each time #{inspect(agent)} runs. Declarations are evaluated on " <>
      "every call, so #{loss}, and every call leaves new ETS tables behind. Create the #{noun} once, " <>
      "in your application's supervision tree or a test's setup, and #{keep}; or use #{durable}, " <>
      "which keeps its data in your database."
  end

  defp schema_entry({:field, type, opts}), do: BeamWeaver.Agent.Schema.field(nil, type, opts)

  def block_expressions({:__block__, _meta, expressions}), do: expressions
  def block_expressions(expression), do: [expression]

  @block_hints %{
    tools: {"tools", ""},
    middleware: {"middleware", ". Use `use MyMiddleware` or `include my_middleware_list`."},
    subagents: {"subagent", ". Use `subagent MyAgent` or `include subagent_specs`."},
    async_subagents: {"async subagent", ". Use `async_subagent \"name\", opts` or `include async_specs`."}
  }

  @doc false
  # Expands a `tools do`, `middleware do`, `subagents do`, or `async_subagents do`
  # block into one flattened list expression.
  def block_ast!(caller, kind, block) do
    entries = block |> block_expressions() |> Enum.map(&block_entry!(caller, kind, &1))

    quote do
      List.flatten([unquote_splicing(entries)])
    end
  end

  def graph_block_entries!(caller, block) do
    block
    |> block_expressions()
    |> Enum.reduce(%{nodes: [], edges: [], reducers: [], channels: [], joins: []}, fn expression, acc ->
      graph_block_entry!(caller, expression, acc)
    end)
  end

  defp block_entry!(_caller, _kind, {:include, _meta, [list_ast]}), do: list_ast

  defp block_entry!(_caller, :tools, {:tool, _meta, [tool_ast]}), do: tool_ast

  defp block_entry!(_caller, :tools, {:tool, _meta, [tool_ast, opts_ast]}),
    do: quote(do: {unquote(tool_ast), unquote(opts_ast)})

  defp block_entry!(_caller, :middleware, {:use, _meta, [module_ast]}), do: module_ast

  defp block_entry!(_caller, :middleware, {:use, _meta, [module_ast, opts_ast]}),
    do: quote(do: {unquote(module_ast), unquote(opts_ast)})

  defp block_entry!(_caller, :subagents, {:subagent, _meta, [module_ast]}),
    do: quote(do: BeamWeaver.Agent.Subagent.Spec.from_agent_module(unquote(module_ast), []))

  defp block_entry!(_caller, :subagents, {:subagent, _meta, [module_ast, opts_ast]}),
    do: quote(do: BeamWeaver.Agent.Subagent.Spec.from_agent_module(unquote(module_ast), unquote(opts_ast)))

  defp block_entry!(_caller, :async_subagents, {:async_subagent, _meta, [opts_ast]}),
    do: quote(do: BeamWeaver.Agent.Subagent.AsyncSpec.new(unquote(opts_ast)))

  defp block_entry!(_caller, :async_subagents, {:async_subagent, _meta, [name_ast, opts_ast]}) do
    quote do
      unquote(opts_ast)
      |> Keyword.put_new(:name, unquote(name_ast))
      |> BeamWeaver.Agent.Subagent.AsyncSpec.new()
    end
  end

  defp block_entry!(caller, kind, other) do
    {label, hint} = Map.fetch!(@block_hints, kind)

    raise CompileError,
      file: caller.file,
      line: caller.line,
      description: "unsupported #{label} declaration: #{Macro.to_string(other)}#{hint}"
  end

  defp graph_block_entry!(caller, {:state, _meta, [[do: state_block]]}, acc) do
    channels =
      state_block
      |> block_expressions()
      |> Enum.map(&state_channel_entry!(caller, &1))

    %{acc | channels: acc.channels ++ channels}
  end

  defp graph_block_entry!(_caller, {:node, _meta, [name, fun_ast]}, acc) do
    %{acc | nodes: acc.nodes ++ [{name, fun_ast, []}]}
  end

  defp graph_block_entry!(_caller, {:node, _meta, [name, fun_ast, opts]}, acc) do
    %{acc | nodes: acc.nodes ++ [{name, fun_ast, opts}]}
  end

  defp graph_block_entry!(_caller, {:edge, _meta, [start_node, end_node]}, acc) do
    %{acc | edges: acc.edges ++ [{graph_node_ast(start_node), graph_node_ast(end_node), []}]}
  end

  defp graph_block_entry!(_caller, {:edge, _meta, [start_node, end_node, opts]}, acc) do
    %{acc | edges: acc.edges ++ [{graph_node_ast(start_node), graph_node_ast(end_node), opts}]}
  end

  defp graph_block_entry!(_caller, {:join, _meta, [upstream_nodes, downstream_node]}, acc) do
    %{acc | joins: acc.joins ++ [{upstream_nodes, graph_node_ast(downstream_node), []}]}
  end

  defp graph_block_entry!(_caller, {:join, _meta, [upstream_nodes, downstream_node, opts]}, acc) do
    %{acc | joins: acc.joins ++ [{upstream_nodes, graph_node_ast(downstream_node), opts}]}
  end

  defp graph_block_entry!(_caller, {:reducer, _meta, [key, reducer_ast]}, acc) do
    %{acc | reducers: acc.reducers ++ [{key, reducer_ast}]}
  end

  defp graph_block_entry!(caller, other, _acc) do
    raise CompileError,
      file: caller.file,
      line: caller.line,
      description: "unsupported graph declaration: #{Macro.to_string(other)}"
  end

  defp state_channel_entry!(_caller, {:channel, _meta, [key]}), do: {key, :last, []}

  defp state_channel_entry!(_caller, {:channel, _meta, [key, opts]}) do
    {key, Keyword.get(opts, :merge, :last), Keyword.delete(opts, :merge)}
  end

  defp state_channel_entry!(caller, other) do
    raise CompileError,
      file: caller.file,
      line: caller.line,
      description: "unsupported graph state declaration: #{Macro.to_string(other)}"
  end

  defp graph_node_ast({:start, _meta, []}), do: quote(do: BeamWeaver.Graph.start())
  defp graph_node_ast({:finish, _meta, []}), do: quote(do: BeamWeaver.Graph.end_node())
  defp graph_node_ast(other), do: other

  defp schema_block_entry!(caller, _target, {:field, _meta, [name_ast, type_ast]}) do
    schema_block_entry!(caller, :context, {:field, [], [name_ast, type_ast, []]})
  end

  defp schema_block_entry!(caller, _target, {:field, _meta, [name_ast, type_ast, opts]}) do
    {literal_schema_key!(caller, name_ast), {:field, type_ast, opts}}
  end

  defp schema_block_entry!(caller, :context, {name, _meta, _args})
       when name in [:channel, :private_channel, :managed] do
    raise CompileError,
      file: caller.file,
      line: caller.line,
      description: "context_schema blocks only support field/2 and field/3 declarations"
  end

  defp schema_block_entry!(caller, _target, other) do
    raise CompileError,
      file: caller.file,
      line: caller.line,
      description: "unsupported agent schema declaration: #{Macro.to_string(other)}"
  end

  defp literal_schema_key!(_caller, key) when is_atom(key), do: key

  defp literal_schema_key!(caller, other) do
    expanded = Macro.expand(other, caller)

    if is_atom(expanded) do
      expanded
    else
      raise CompileError,
        file: caller.file,
        line: caller.line,
        description: "agent schema keys must be literal atoms"
    end
  end

  defp schema_entry_quote({key, {:field, type_ast, opts_ast}}) do
    quote do
      {unquote(Macro.escape(key)), {:field, unquote(type_ast), unquote(opts_ast)}}
    end
  end

  defp duplicates(values) do
    values
    |> Enum.frequencies()
    |> Enum.filter(fn {_value, count} -> count > 1 end)
    |> Enum.map(fn {value, _count} -> value end)
  end
end
