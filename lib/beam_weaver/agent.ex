defmodule BeamWeaver.Agent do
  @moduledoc """
  Behaviour and DSL for user-defined BeamWeaver agents.

  Agents are normal Elixir modules. The DSL builds a graph at runtime, while
  compile-time checks catch common static mistakes such as duplicate node names
  and missing entry points.
  """

  alias BeamWeaver.Agent.Built
  alias BeamWeaver.Agent.DSL
  alias BeamWeaver.Agent.Spec
  alias BeamWeaver.Core.Async
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Graph.Compiled
  alias BeamWeaver.Graph.StateGraph

  @type input :: map()
  @type agent_module :: module()
  @type built_agent :: Built.t()

  @callback graph() :: StateGraph.t() | Compiled.t()
  @callback __beam_weaver_agent_spec__() :: Spec.t()
  @callback checkpointer() :: struct() | nil
  @callback store() :: struct() | nil

  defmacro __using__(_opts) do
    BeamWeaver.Agent.Use.quoted()
  end

  defmacro node(name, fun_ast, opts \\ []) do
    quote bind_quoted: [name: name, fun_ast: Macro.escape(fun_ast), opts: opts] do
      @beam_weaver_nodes {name, fun_ast, opts}
    end
  end

  defmacro edge(start_node, end_node, opts \\ []) do
    quote bind_quoted: [start_node: start_node, end_node: end_node, opts: opts] do
      @beam_weaver_edges {start_node, end_node, opts}
    end
  end

  defmacro reducer(key, reducer_ast) do
    quote bind_quoted: [key: key, reducer_ast: Macro.escape(reducer_ast)] do
      @beam_weaver_reducers {key, reducer_ast}
    end
  end

  defmacro model(expr_ast) do
    quote bind_quoted: [expr_ast: Macro.escape(expr_ast)] do
      @beam_weaver_model expr_ast
      @beam_weaver_model_opts []
    end
  end

  defmacro model(expr_ast, opts) do
    quote bind_quoted: [expr_ast: Macro.escape(expr_ast), opts: opts] do
      @beam_weaver_model expr_ast
      @beam_weaver_model_opts opts
    end
  end

  for {macro_name, attr} <- DSL.simple_macro_fields() do
    defmacro unquote(macro_name)(expr_ast) do
      attr = unquote(attr)

      quote bind_quoted: [attr: attr, expr_ast: Macro.escape(expr_ast)] do
        Module.put_attribute(__MODULE__, attr, expr_ast)
      end
    end
  end

  defmacro tools(do: block) do
    tools_ast = DSL.tools_block_ast!(__CALLER__, block)

    quote bind_quoted: [tools_ast: Macro.escape(tools_ast)] do
      @beam_weaver_tools tools_ast
    end
  end

  defmacro tools(expr_ast) do
    quote bind_quoted: [expr_ast: Macro.escape(expr_ast)] do
      @beam_weaver_tools expr_ast
    end
  end

  defmacro middleware(do: block) do
    middleware_ast = DSL.middleware_block_ast!(__CALLER__, block)

    quote bind_quoted: [middleware_ast: Macro.escape(middleware_ast)] do
      @beam_weaver_middleware middleware_ast
    end
  end

  defmacro middleware(expr_ast) do
    quote bind_quoted: [expr_ast: Macro.escape(expr_ast)] do
      @beam_weaver_middleware expr_ast
    end
  end

  defmacro subagents(do: block) do
    subagents_ast = DSL.subagents_block_ast!(__CALLER__, block)

    quote bind_quoted: [subagents_ast: Macro.escape(subagents_ast)] do
      @beam_weaver_subagents subagents_ast
    end
  end

  defmacro subagents(expr_ast) do
    quote bind_quoted: [expr_ast: Macro.escape(expr_ast)] do
      @beam_weaver_subagents expr_ast
    end
  end

  defmacro async_subagents(do: block) do
    async_subagents_ast = DSL.async_subagents_block_ast!(__CALLER__, block)

    quote bind_quoted: [async_subagents_ast: Macro.escape(async_subagents_ast)] do
      @beam_weaver_async_subagents async_subagents_ast
    end
  end

  defmacro async_subagents(expr_ast) do
    quote bind_quoted: [expr_ast: Macro.escape(expr_ast)] do
      @beam_weaver_async_subagents expr_ast
    end
  end

  defmacro graph(do: block) do
    entries = DSL.graph_block_entries!(__CALLER__, block)

    node_quotes =
      Enum.map(entries.nodes, fn {name, fun_ast, opts} ->
        quote do
          @beam_weaver_nodes {unquote(name), unquote(Macro.escape(fun_ast)), unquote(opts)}
        end
      end)

    edge_quotes =
      Enum.map(entries.edges, fn {start_node, end_node, opts} ->
        quote do
          @beam_weaver_edges {unquote(start_node), unquote(end_node), unquote(opts)}
        end
      end)

    reducer_quotes =
      Enum.map(entries.reducers, fn {key, reducer_ast} ->
        quote do
          @beam_weaver_reducers {unquote(key), unquote(Macro.escape(reducer_ast))}
        end
      end)

    channel_quotes =
      Enum.map(entries.channels, fn {key, merge, opts} ->
        quote do
          @beam_weaver_channels {unquote(key), unquote(Macro.escape(merge)), unquote(opts)}
        end
      end)

    join_quotes =
      Enum.map(entries.joins, fn {upstream_nodes, downstream_node, opts} ->
        quote do
          @beam_weaver_joins {unquote(upstream_nodes), unquote(downstream_node), unquote(opts)}
        end
      end)

    quote do
      unquote_splicing(channel_quotes)
      unquote_splicing(reducer_quotes)
      unquote_splicing(node_quotes)
      unquote_splicing(edge_quotes)
      unquote_splicing(join_quotes)
    end
  end

  defmacro response_schema(schema_ast, opts_ast \\ []) do
    response_ast =
      quote do
        BeamWeaver.Agent.__response_schema__(
          unquote(schema_ast),
          unquote(opts_ast)
        )
      end

    quote do
      @beam_weaver_response_format unquote(Macro.escape(response_ast))
    end
  end

  defmacro response_format(expr_ast) do
    quote bind_quoted: [expr_ast: Macro.escape(expr_ast)] do
      @beam_weaver_response_format expr_ast
    end
  end

  defmacro context_schema(do: block) do
    entry_quotes =
      __CALLER__
      |> DSL.schema_block_entries!(:context, block)
      |> Enum.map(fn entry ->
        quote do
          @beam_weaver_context_schema_entries unquote(Macro.escape(entry))
        end
      end)

    quote do
      (unquote_splicing(entry_quotes))
    end
  end

  defmacro context_schema(expr_ast) do
    quote bind_quoted: [expr_ast: Macro.escape(expr_ast)] do
      @beam_weaver_context_schema expr_ast
    end
  end

  defmacro interrupts(opts) do
    quote bind_quoted: [opts: opts] do
      @beam_weaver_interrupt_before Keyword.get(opts, :before, [])
      @beam_weaver_interrupt_after Keyword.get(opts, :after, [])
    end
  end

  defmacro field(name, type, opts \\ []) do
    target = Module.get_attribute(__CALLER__.module, :beam_weaver_schema_target)
    attr = DSL.schema_attr!(target, :field, __CALLER__)

    quote bind_quoted: [attr: attr, name: name, type: Macro.escape(type), opts: opts] do
      Module.put_attribute(__MODULE__, attr, {name, {:field, type, opts}})
    end
  end

  defmacro __before_compile__(env) do
    BeamWeaver.Agent.BeforeCompile.compile(env)
  end

  def __schema_from_entries__(base, entries) do
    DSL.schema_from_entries(base, entries)
  end

  def __response_schema__(schema, opts) do
    opts = List.wrap(opts)

    schema =
      schema
      |> BeamWeaver.Schema.to_json_schema()
      |> maybe_put_schema_title(Keyword.get(opts, :name))
      |> maybe_put_schema_description(Keyword.get(opts, :description))

    strategy = Keyword.get(opts, :strategy, :auto)

    strategy_opts =
      opts
      |> Keyword.take([:name, :description, :strict, :tool_message_content, :handle_errors])

    case strategy do
      :auto -> BeamWeaver.Agent.StructuredOutput.auto(schema)
      :tool -> BeamWeaver.Agent.StructuredOutput.tool(schema, strategy_opts)
      :provider -> BeamWeaver.Agent.StructuredOutput.provider(schema, strategy_opts)
      other -> raise ArgumentError, "unknown response_schema strategy #{inspect(other)}"
    end
  end

  def __add_graph_channel__(graph, key, merge, opts) do
    alias BeamWeaver.Graph.Channels.BinaryOperatorAggregate
    alias BeamWeaver.Graph.Channels.LastValue

    case merge do
      :last ->
        BeamWeaver.Graph.add_channel(graph, key, LastValue, opts)

      :map ->
        BeamWeaver.Graph.add_channel(
          graph,
          key,
          {BinaryOperatorAggregate, &Map.merge/2},
          Keyword.put_new(opts, :initial, %{})
        )

      :list ->
        BeamWeaver.Graph.add_channel(
          graph,
          key,
          {BinaryOperatorAggregate, fn left, right -> List.wrap(left) ++ List.wrap(right) end},
          Keyword.put_new(opts, :initial, [])
        )

      reducer when is_function(reducer, 2) ->
        BeamWeaver.Graph.add_channel(graph, key, {BinaryOperatorAggregate, reducer}, opts)

      other ->
        raise ArgumentError, "unknown graph state channel merge #{inspect(other)}"
    end
  end

  defp maybe_put_schema_title(schema, nil), do: schema
  defp maybe_put_schema_title(schema, name) when is_map(schema), do: Map.put(schema, "title", to_string(name))

  defp maybe_put_schema_description(schema, nil), do: schema

  defp maybe_put_schema_description(schema, description) when is_map(schema),
    do: Map.put(schema, "description", to_string(description))

  @doc """
  Builds a runtime agent from an options map or keyword list.

  The returned agent uses the same `%BeamWeaver.Agent.Spec{}` and graph compiler
  as the `use BeamWeaver.Agent` DSL. Prefer module-defined agents for stable
  application code; use this for config-driven or user-generated workflows.
  """
  @spec build(keyword() | map()) :: {:ok, Built.t()} | {:error, Error.t()}
  defdelegate build(opts), to: BeamWeaver.Agent.Builder

  @doc """
  Invokes an agent module.
  """
  @spec invoke(agent_module(), input(), keyword()) ::
          {:ok, map()} | {:interrupted, map()} | {:error, Error.t()}
  @spec invoke(built_agent(), input(), keyword()) ::
          {:ok, map()} | {:interrupted, map()} | {:error, Error.t()}
  defdelegate invoke(agent, input, opts \\ []), to: BeamWeaver.Agent.Runner

  @doc """
  Starts a Task-backed agent invocation.
  """
  @spec async_invoke(agent_module() | built_agent(), input(), keyword()) :: Async.handle()
  defdelegate async_invoke(agent, input, opts \\ []), to: BeamWeaver.Agent.Runner

  @doc """
  Streams typed event envelopes from an agent invocation.
  """
  @spec stream_events(agent_module(), input(), keyword()) ::
          {:ok, Enumerable.t()} | {:interrupted, map()} | {:error, Error.t()}
  @spec stream_events(built_agent(), input(), keyword()) ::
          {:ok, Enumerable.t()} | {:interrupted, map()} | {:error, Error.t()}
  defdelegate stream_events(agent, input, opts \\ []), to: BeamWeaver.Agent.Runner

  @doc """
  Resumes the latest interrupted checkpoint for an agent module.
  """
  @spec resume(agent_module(), term(), keyword()) ::
          {:ok, map()} | {:interrupted, map()} | {:error, Error.t()}
  @spec resume(built_agent(), term(), keyword()) ::
          {:ok, map()} | {:interrupted, map()} | {:error, Error.t()}
  defdelegate resume(agent, resume, opts \\ []), to: BeamWeaver.Agent.Runner

  @doc """
  Resumes an agent from framework-agnostic HITL review decisions.
  """
  @spec resume_review(agent_module(), term(), keyword()) ::
          {:ok, map()} | {:interrupted, map()} | {:error, Error.t()}
  defdelegate resume_review(agent_module, review_or_decisions, opts \\ []),
    to: BeamWeaver.Agent.Runner

  @doc """
  Returns the latest checkpoint state for an agent module.
  """
  @spec get_state(agent_module(), keyword() | map()) ::
          {:ok, map()} | :error | {:error, Error.t()}
  @spec get_state(built_agent(), keyword() | map()) :: {:ok, map()} | :error | {:error, Error.t()}
  defdelegate get_state(agent, opts \\ []), to: BeamWeaver.Agent.Runner

  @doc """
  Compiles the graph for an agent module.
  """
  @spec compiled_graph(agent_module(), keyword()) :: {:ok, Compiled.t()} | {:error, Error.t()}
  defdelegate compiled_graph(agent_module, opts \\ []), to: BeamWeaver.Agent.Runner
end
