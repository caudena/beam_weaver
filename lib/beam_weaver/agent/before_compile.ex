defmodule BeamWeaver.Agent.BeforeCompile do
  @moduledoc false

  alias BeamWeaver.Agent.DSL

  def compile(env) do
    nodes = Module.get_attribute(env.module, :beam_weaver_nodes) |> Enum.reverse()
    edges = Module.get_attribute(env.module, :beam_weaver_edges) |> Enum.reverse()

    reducers = Module.get_attribute(env.module, :beam_weaver_reducers) |> Enum.reverse()
    channels = Module.get_attribute(env.module, :beam_weaver_channels) |> Enum.reverse()
    joins = Module.get_attribute(env.module, :beam_weaver_joins) |> Enum.reverse()
    attrs = DSL.collect_attrs(env.module)
    graph_defined? = Module.defines?(env.module, {:graph, 0})

    DSL.validate_static_agent!(
      env,
      nodes,
      edges,
      graph_defined?,
      attrs.model,
      attrs.tools,
      attrs.validate_tools,
      attrs.system_prompt,
      attrs.middleware,
      attrs.response_format
    )

    DSL.reject_in_memory_adapters!(env, attrs, nodes)

    {storage_quotes, attrs} = storage_callbacks(env, attrs)

    context_schema_quote = DSL.schema_quote(attrs.context_schema, attrs.context_schema_entries)
    model_opts_quote = DSL.model_opts_quote(attrs.model_options, attrs.model_opts)

    spec_quote =
      DSL.spec_quote(env.module, %{attrs | context_schema: context_schema_quote, model_opts: model_opts_quote})

    graph_quote =
      cond do
        graph_defined? ->
          []

        attrs.model ->
          DSL.agent_compiler_graph_quote()

        true ->
          DSL.graph_builder_quote(
            env.module,
            nodes,
            edges,
            reducers,
            channels,
            joins
          )
      end

    quote do
      unquote(spec_quote)
      unquote_splicing(List.wrap(graph_quote))
      unquote_splicing(storage_quotes)
    end
  end

  # `checkpointer/0` and `store/0` return what the declarations of the same
  # name evaluate to, `nil` when there is none. A module may define either
  # function instead of declaring it, and then runs with what it returns.
  # (A definition here can't override one from `use`, so `use` defines none.)
  defp storage_callbacks(env, attrs) do
    Enum.flat_map_reduce([:checkpointer, :store], attrs, fn name, attrs ->
      declared = Map.fetch!(attrs, name)

      cond do
        not Module.defines?(env.module, {name, 0}) ->
          callback =
            quote do
              @impl BeamWeaver.Agent
              def unquote(name)(), do: unquote(declared)
            end

          {[callback], attrs}

        is_nil(declared) ->
          {[], Map.put(attrs, name, quote(do: unquote(name)()))}

        true ->
          raise CompileError,
            file: env.file,
            line: env.line,
            description: "#{inspect(env.module)} declares `#{name}` and defines #{name}/0; keep one of them"
      end
    end)
  end
end
