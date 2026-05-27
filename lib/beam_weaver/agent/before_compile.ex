defmodule BeamWeaver.Agent.BeforeCompile do
  @moduledoc false

  alias BeamWeaver.Agent.DSL

  def compile(env) do
    nodes = Module.get_attribute(env.module, :beam_weaver_nodes) |> Enum.reverse()
    edges = Module.get_attribute(env.module, :beam_weaver_edges) |> Enum.reverse()

    reducers = Module.get_attribute(env.module, :beam_weaver_reducers) |> Enum.reverse()
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

    context_schema_quote = DSL.schema_quote(attrs.context_schema, attrs.context_schema_entries)

    spec_quote =
      DSL.spec_quote(env.module, %{attrs | context_schema: context_schema_quote})

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
            reducers
          )
      end

    checkpointer_quote =
      if attrs.checkpointer do
        quote do
          @impl BeamWeaver.Agent
          def checkpointer, do: unquote(attrs.checkpointer)
        end
      end

    store_quote =
      if attrs.store do
        quote do
          @impl BeamWeaver.Agent
          def store, do: unquote(attrs.store)
        end
      end

    quote do
      unquote(spec_quote)
      unquote_splicing(List.wrap(graph_quote))
      unquote(checkpointer_quote)
      unquote(store_quote)
    end
  end
end
