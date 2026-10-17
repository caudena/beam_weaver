defmodule BeamWeaver.Agent.DSL do
  @moduledoc false

  @graph_fields [:nodes, :edges, :reducers, :channels, :joins]

  @dsl_fields ~w(name description model model_options model_opts tools validate_tools middleware filesystem
                 filesystem_permissions skills memory subagents async_subagents compact_conversation
                 overflow_recovery prompt_caching exclude_tools tool_descriptions interrupt_on system_prompt
                 response_format checkpointer store cache context_schema input_schema output_schema
                 interrupt_before interrupt_after recursion_limit execution_mode capability_profile tool_timeout
                 step_timeout run_timeout)a

  @special_macros ~w(model model_options context_schema tools middleware subagents async_subagents response_format)a

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

  def simple_macro_fields, do: for(name <- @dsl_fields -- @special_macros, do: {name, attr(name)})

  def register_attribute_quotes do
    for name <- @dsl_fields ++ [:context_schema_entries | @graph_fields] do
      quote do
        Module.register_attribute(__MODULE__, unquote(attr(name)), accumulate: unquote(name not in @dsl_fields))
      end
    end
  end

  def collect_attrs(module) do
    @dsl_fields
    |> Map.new(&{&1, Module.get_attribute(module, attr(&1))})
    |> Map.put(:context_schema_entries, collect(module, :context_schema_entries))
  end

  def collect_graph(module), do: Map.new(@graph_fields, &{&1, collect(module, &1)})

  defp collect(module, name), do: module |> Module.get_attribute(attr(name)) |> Enum.reverse()

  defp attr(name), do: :"beam_weaver_#{name}"

  def schema_from_entries(base, entries) do
    Enum.reduce(entries, base || %{}, fn {key, declaration}, acc ->
      Map.put(acc, key, schema_entry(declaration))
    end)
  end

  def schema_block_entries!(caller, block),
    do: block |> block_expressions() |> Enum.map(&schema_block_entry!(caller, &1))

  def schema_quote(nil, []), do: nil

  def schema_quote(schema_ast, entries) do
    base = schema_ast || quote(do: %{})
    entries_ast = Enum.map(entries, &schema_entry_quote/1)

    quote do
      BeamWeaver.Agent.DSL.schema_from_entries(unquote(base), [unquote_splicing(entries_ast)])
    end
  end

  def spec_quote(attrs) do
    attrs_ast = {:%{}, [], for(name <- @dsl_fields, name != :model_options, do: {name, Map.fetch!(attrs, name)})}

    quote do
      @impl BeamWeaver.Agent
      def __beam_weaver_agent_spec__ do
        BeamWeaver.Agent.Spec.from_dsl_attrs(__MODULE__, unquote(attrs_ast))
      end
    end
  end

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

  def graph_builder_quote(module, graph) do
    calls =
      Enum.map(graph.channels, fn {key, merge, opts} ->
        {BeamWeaver.Agent, :__add_graph_channel__, [key, merge, Macro.escape(opts)]}
      end) ++
        Enum.map(graph.reducers, fn {key, reducer_ast} -> {BeamWeaver.Graph, :add_reducer, [key, reducer_ast]} end) ++
        Enum.map(graph.nodes, fn {name, fun_ast, opts} ->
          {BeamWeaver.Graph, :add_node, [name, fun_ast, Macro.escape(opts)]}
        end) ++
        Enum.map(graph.edges, fn {from, to, opts} -> {BeamWeaver.Graph, :add_edge, [from, to, Macro.escape(opts)]} end) ++
        Enum.map(graph.joins, fn {from_nodes, to_node, opts} ->
          {BeamWeaver.Graph, :add_join, [from_nodes, to_node, Macro.escape(opts)]}
        end)

    steps =
      for {builder, fun, args} <- calls,
          do: quote(do: graph = unquote(builder).unquote(fun)(graph, unquote_splicing(args)))

    quote do
      @impl BeamWeaver.Agent
      def graph do
        graph = BeamWeaver.Graph.new(name: inspect(unquote(module)))
        unquote_splicing(steps)
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

  def validate_static_agent!(env, graph, graph_defined?, attrs) do
    duplicate_names =
      for {name, count} <- Enum.frequencies_by(graph.nodes, &to_string(elem(&1, 0))), count > 1, do: name

    if duplicate_names != [] do
      compile_error!(env, "duplicate BeamWeaver agent node names: #{Enum.join(duplicate_names, ", ")}")
    end

    if graph.nodes != [] and not Enum.any?(graph.edges, &match?({:__start__, _end_node, _opts}, &1)) do
      compile_error!(env, "BeamWeaver agent DSL must define an edge from Graph.start()")
    end

    if graph_defined? and
         (attrs.model || attrs.tools || attrs.validate_tools || attrs.system_prompt || attrs.middleware ||
            attrs.response_format) do
      compile_error!(env, "BeamWeaver agent model/tools DSL cannot be combined with a custom graph/0")
    end

    if attrs.model && (graph.nodes != [] or graph.edges != []) do
      compile_error!(
        env,
        "BeamWeaver agent model/tools DSL builds its own graph; use graph/0 for custom graph composition"
      )
    end

    if is_nil(attrs.model) and (attrs.tools || attrs.validate_tools || attrs.system_prompt || attrs.response_format) do
      compile_error!(
        env,
        "BeamWeaver agent tools/validate_tools/system_prompt/response_format declarations require model/1"
      )
    end
  end

  def compile_error!(env, description),
    do: raise(CompileError, file: env.file, line: env.line, description: description)

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

  defp block_expressions({:__block__, _meta, expressions}), do: expressions
  defp block_expressions(expression), do: [expression]

  @block_hints %{
    tools: {"tools", ""},
    middleware: {"middleware", ". Use `use MyMiddleware` or `include my_middleware_list`."},
    subagents: {"subagent", ". Use `subagent MyAgent` or `include subagent_specs`."},
    async_subagents: {"async subagent", ". Use `async_subagent \"name\", opts` or `include async_specs`."}
  }

  # Expands a `tools do`, `middleware do`, `subagents do`, or `async_subagents do`
  # block into one flattened list expression.
  def block_ast!(caller, kind, block) do
    entries = block |> block_expressions() |> Enum.map(&block_entry!(caller, kind, &1))

    quote do
      List.flatten([unquote_splicing(entries)])
    end
  end

  def graph_block_entries!(caller, block),
    do: block |> block_expressions() |> Enum.flat_map(&graph_block_entry!(caller, &1))

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
    compile_error!(caller, "unsupported #{label} declaration: #{Macro.to_string(other)}#{hint}")
  end

  defp graph_block_entry!(caller, {:state, _meta, [[do: state_block]]}) do
    for expression <- block_expressions(state_block) do
      {key, merge, opts} = state_channel_entry!(caller, expression)
      {:beam_weaver_channels, quote(do: {unquote(key), unquote(Macro.escape(merge)), unquote(opts)})}
    end
  end

  defp graph_block_entry!(caller, {kind, meta, [first, second]}) when kind in [:node, :edge, :join],
    do: graph_block_entry!(caller, {kind, meta, [first, second, []]})

  defp graph_block_entry!(_caller, {:node, _meta, [name, fun_ast, opts]}),
    do: [{:beam_weaver_nodes, quote(do: {unquote(name), unquote(Macro.escape(fun_ast)), unquote(opts)})}]

  defp graph_block_entry!(_caller, {:edge, _meta, [start_node, end_node, opts]}) do
    [
      {:beam_weaver_edges,
       quote(do: {unquote(graph_node_ast(start_node)), unquote(graph_node_ast(end_node)), unquote(opts)})}
    ]
  end

  defp graph_block_entry!(_caller, {:join, _meta, [upstream_nodes, downstream_node, opts]}) do
    [
      {:beam_weaver_joins,
       quote(do: {unquote(upstream_nodes), unquote(graph_node_ast(downstream_node)), unquote(opts)})}
    ]
  end

  defp graph_block_entry!(_caller, {:reducer, _meta, [key, reducer_ast]}),
    do: [{:beam_weaver_reducers, quote(do: {unquote(key), unquote(Macro.escape(reducer_ast))})}]

  defp graph_block_entry!(caller, other),
    do: compile_error!(caller, "unsupported graph declaration: #{Macro.to_string(other)}")

  defp state_channel_entry!(_caller, {:channel, _meta, [key]}), do: {key, :last, []}

  defp state_channel_entry!(_caller, {:channel, _meta, [key, opts]}) do
    {key, Keyword.get(opts, :merge, :last), Keyword.delete(opts, :merge)}
  end

  defp state_channel_entry!(caller, other),
    do: compile_error!(caller, "unsupported graph state declaration: #{Macro.to_string(other)}")

  defp graph_node_ast({:start, _meta, []}), do: quote(do: BeamWeaver.Graph.start())
  defp graph_node_ast({:finish, _meta, []}), do: quote(do: BeamWeaver.Graph.end_node())
  defp graph_node_ast(other), do: other

  defp schema_block_entry!(caller, {:field, meta, [name_ast, type_ast]}),
    do: schema_block_entry!(caller, {:field, meta, [name_ast, type_ast, []]})

  defp schema_block_entry!(caller, {:field, _meta, [name_ast, type_ast, opts]}) do
    {literal_schema_key!(caller, name_ast), {:field, type_ast, opts}}
  end

  defp schema_block_entry!(caller, {name, _meta, _args}) when name in [:channel, :private_channel, :managed],
    do: compile_error!(caller, "context_schema blocks only support field/2 and field/3 declarations")

  defp schema_block_entry!(caller, other),
    do: compile_error!(caller, "unsupported agent schema declaration: #{Macro.to_string(other)}")

  defp literal_schema_key!(_caller, key) when is_atom(key), do: key

  defp literal_schema_key!(caller, other) do
    expanded = Macro.expand(other, caller)

    if is_atom(expanded), do: expanded, else: compile_error!(caller, "agent schema keys must be literal atoms")
  end

  defp schema_entry_quote({key, {:field, type_ast, opts_ast}}) do
    quote do
      {unquote(Macro.escape(key)), {:field, unquote(type_ast), unquote(opts_ast)}}
    end
  end
end
