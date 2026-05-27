defmodule BeamWeaver.Agent.DSL do
  @moduledoc false

  @graph_attributes [
    beam_weaver_nodes: true,
    beam_weaver_edges: true,
    beam_weaver_reducers: true
  ]

  @dsl_fields [
    name: [attr: :beam_weaver_name],
    checkpointer: [attr: :beam_weaver_checkpointer],
    store: [attr: :beam_weaver_store],
    cache: [attr: :beam_weaver_cache],
    model: [attr: :beam_weaver_model],
    model_opts: [attr: :beam_weaver_model_opts, default: []],
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
    debug: [attr: :beam_weaver_debug],
    recursion_limit: [attr: :beam_weaver_recursion_limit]
  ]

  @special_macros [:model, :context_schema, :context_schema_entries, :schema_target]

  @spec_quote_fields [
    {:name, nil, :ast},
    {:model, nil, :ast},
    {:model_opts, [], :escape},
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
    {:debug, false, :ast},
    {:recursion_limit, nil, :ast}
  ]

  def imports do
    [
      node: 2,
      node: 3,
      edge: 2,
      edge: 3,
      reducer: 2,
      model: 1,
      model: 2,
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

  defp spec_attr_value_ast(nil, default, :escape), do: Macro.escape(default)
  defp spec_attr_value_ast(value, _default, :escape), do: Macro.escape(value)
  defp spec_attr_value_ast(nil, default, :ast), do: default
  defp spec_attr_value_ast(value, _default, :ast), do: value

  def graph_builder_quote(
        module,
        nodes,
        edges,
        reducers
      ) do
    node_quotes =
      Enum.map(nodes, fn {name, fun_ast, opts} ->
        quote do
          graph = BeamWeaver.Graph.add_node(graph, unquote(name), unquote(fun_ast), unquote(opts))
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

    quote do
      @impl BeamWeaver.Agent
      def graph do
        graph = BeamWeaver.Graph.new(name: inspect(unquote(module)))
        unquote_splicing(reducer_quotes)
        unquote_splicing(node_quotes)
        unquote_splicing(edge_quotes)
        graph
      end
    end
  end

  def agent_compiler_graph_quote do
    quote do
      @impl BeamWeaver.Agent
      def graph do
        BeamWeaver.Agent.Compiler.compile_graph(__beam_weaver_agent_spec__())
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
           start_node in [:__start__, "__start__"]
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

  defp schema_entry({:field, type, opts}), do: BeamWeaver.Agent.Schema.field(nil, type, opts)

  defp block_expressions({:__block__, _meta, expressions}), do: expressions
  defp block_expressions(expression), do: [expression]

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

  defp literal_schema_key!(_caller, key) when is_atom(key) or is_binary(key), do: key

  defp literal_schema_key!(caller, other) do
    expanded = Macro.expand(other, caller)

    if is_atom(expanded) or is_binary(expanded) do
      expanded
    else
      raise CompileError,
        file: caller.file,
        line: caller.line,
        description: "agent schema keys must be literal atoms or strings"
    end
  end

  defp schema_entry_quote({key, {:field, type_ast, opts}}) do
    quote do
      {unquote(Macro.escape(key)), {:field, unquote(type_ast), unquote(Macro.escape(opts))}}
    end
  end

  defp duplicates(values) do
    values
    |> Enum.frequencies()
    |> Enum.filter(fn {_value, count} -> count > 1 end)
    |> Enum.map(fn {value, _count} -> value end)
  end
end
