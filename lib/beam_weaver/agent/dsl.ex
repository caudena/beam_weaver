defmodule BeamWeaver.Agent.DSL do
  @moduledoc false

  alias BeamWeaver.Graph.DSL, as: GraphDSL

  @dsl_fields ~w(name description model model_options model_opts tools validate_tools middleware filesystem
                 filesystem_permissions skills memory subagents async_subagents compact_conversation
                 overflow_recovery prompt_caching exclude_tools tool_descriptions interrupt_on system_prompt
                 response_format checkpointer store cache context_schema input_schema output_schema
                 interrupt_before interrupt_after recursion_limit execution_mode capability_profile tool_timeout
                 step_timeout run_timeout)a

  @special_macros ~w(model model_options context_schema tools middleware subagents async_subagents response_format)a

  # The declaration a collected attribute comes from, when the names differ.
  @declaration_names %{
    model_options: :model,
    context_schema_entries: :context_schema,
    interrupt_before: :interrupts,
    interrupt_after: :interrupts
  }

  # `graph`, `node`, `edge` and `reducer` only raise: graph modules have them.
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
    for name <- [:context_schema_entries | @dsl_fields] do
      quote do
        Module.register_attribute(__MODULE__, unquote(attr(name)), accumulate: unquote(name not in @dsl_fields))
      end
    end
  end

  def collect_attrs(module) do
    @dsl_fields
    |> Map.new(&{&1, Module.get_attribute(module, attr(&1))})
    |> Map.put(:context_schema_entries, module |> Module.get_attribute(attr(:context_schema_entries)) |> Enum.reverse())
  end

  defp attr(name), do: :"beam_weaver_#{name}"

  def schema_from_entries(base, entries) do
    Enum.reduce(entries, base || %{}, fn {key, {:field, type, opts}}, acc ->
      Map.put(acc, key, BeamWeaver.Agent.Schema.field(nil, type, opts))
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

  # An agent module is a graph module too: its graph is the agent loop.
  def graph_quotes do
    quote do
      @impl BeamWeaver.Graph
      def graph, do: BeamWeaver.Agent.Compiler.module_graph(__beam_weaver_agent_spec__())

      @impl BeamWeaver.Graph
      def compiled_graph(opts \\ []), do: BeamWeaver.Agent.compiled_graph(__MODULE__, opts)
    end
  end

  def validate_static_agent!(env, attrs) do
    cond do
      is_nil(attrs.model) ->
        compile_error!(
          env,
          "#{inspect(env.module)} declares no model. An agent module runs a chat model, declared with " <>
            "`model \"provider:model\"`; a module that runs a graph of its own nodes is a graph module, " <>
            "with `use BeamWeaver.Graph` instead of `use BeamWeaver.Agent`"
        )

      Module.defines?(env.module, {:graph, 0}) ->
        compile_error!(
          env,
          "#{inspect(env.module)} defines graph/0, but an agent module builds its graph from its model, " <>
            "tools and middleware. For a graph of your own, `use BeamWeaver.Graph` in a module of its own"
        )

      true ->
        :ok
    end
  end

  def graph_declaration!(caller, declaration) do
    compile_error!(
      caller,
      "`#{declaration}` declares part of a graph, and an agent module builds its graph from its model, " <>
        "tools and middleware: graph modules `use BeamWeaver.Graph`"
    )
  end

  defdelegate compile_error!(env, description), to: GraphDSL

  # Declarations are evaluated on every call; see
  # `BeamWeaver.Graph.DSL.reject_in_memory_adapters!/3`.
  def reject_in_memory_adapters!(env, attrs) do
    declarations = Enum.map(attrs, fn {name, ast} -> {Map.get(@declaration_names, name, name), ast} end)
    GraphDSL.reject_in_memory_adapters!(env, declarations, [])
  end

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
