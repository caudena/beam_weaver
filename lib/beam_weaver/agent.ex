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
