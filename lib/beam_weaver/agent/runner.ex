defmodule BeamWeaver.Agent.Runner do
  @moduledoc """
  Runtime facade for invoking, streaming, resuming, and inspecting agents.

  `BeamWeaver.Agent` owns the DSL. This module owns execution flow for both
  module-defined agents and runtime-built agents.
  """

  alias BeamWeaver.Agent.Built
  alias BeamWeaver.Agent.Capabilities
  alias BeamWeaver.Agent.Compiler
  alias BeamWeaver.Agent.State
  alias BeamWeaver.Core.Async
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.ID
  alias BeamWeaver.Graph
  alias BeamWeaver.Graph.Compiled
  alias BeamWeaver.Graph.Runtime
  alias BeamWeaver.Graph.StateGraph

  @type input :: map()
  @type agent_module :: module()
  @type built_agent :: Built.t()

  @spec invoke(agent_module(), input(), keyword()) ::
          {:ok, map()} | {:interrupted, map()} | {:error, Error.t()}
  @spec invoke(built_agent(), input(), keyword()) ::
          {:ok, map()} | {:interrupted, map()} | {:error, Error.t()}
  def invoke(agent, input, opts \\ [])

  def invoke(%Built{} = agent, input, opts) when is_map(input) do
    spec = agent.spec |> Capabilities.apply()
    opts = Compiler.run_opts(spec, opts)

    with :ok <- Compiler.validate_runtime!(spec, opts),
         :ok <- BeamWeaver.Agent.Schema.validate_input(spec.input_schema, input),
         _runtime <- built_runtime(agent, opts) do
      input = project_input(input, agent.compiled)

      case Compiled.invoke(agent.compiled, input, opts) do
        {:ok, state} ->
          with :ok <- BeamWeaver.Agent.Schema.validate_output(spec.output_schema, state) do
            {:ok, state}
          end

        other ->
          other
      end
    end
  end

  def invoke(agent_module, input, opts) when is_atom(agent_module) and is_map(input) do
    spec = agent_module.__beam_weaver_agent_spec__() |> Capabilities.apply()
    opts = Compiler.run_opts(spec, opts)

    with :ok <- Compiler.validate_runtime!(spec, opts),
         :ok <- BeamWeaver.Agent.Schema.validate_input(spec.input_schema, input),
         {:ok, compiled} <- compiled_graph(agent_module, opts),
         _runtime <- agent_runtime(agent_module, compiled, opts) do
      input = project_input(input, compiled)

      case Compiled.invoke(compiled, input, opts) do
        {:ok, state} ->
          with :ok <- BeamWeaver.Agent.Schema.validate_output(spec.output_schema, state) do
            {:ok, state}
          end

        other ->
          other
      end
    end
  end

  @spec async_invoke(agent_module() | built_agent(), input(), keyword()) :: Async.handle()
  def async_invoke(agent, input, opts \\ []) do
    Async.run_call(opts, &invoke(agent, input, &1))
  end

  @spec stream_events(agent_module(), input(), keyword()) ::
          {:ok, Enumerable.t()} | {:interrupted, map()} | {:error, Error.t()}
  @spec stream_events(built_agent(), input(), keyword()) ::
          {:ok, Enumerable.t()} | {:interrupted, map()} | {:error, Error.t()}
  def stream_events(agent, input, opts \\ [])

  def stream_events(%Built{} = agent, input, opts) when is_map(input) do
    spec = agent.spec |> Capabilities.apply()
    opts = Compiler.run_opts(spec, opts)

    with :ok <- Compiler.validate_runtime!(spec, opts),
         :ok <- BeamWeaver.Agent.Schema.validate_input(spec.input_schema, input),
         _runtime <- built_runtime(agent, opts) do
      Compiled.stream_events(agent.compiled, project_input(input, agent.compiled), opts)
    end
  end

  def stream_events(agent_module, input, opts) when is_atom(agent_module) and is_map(input) do
    spec = agent_module.__beam_weaver_agent_spec__() |> Capabilities.apply()
    opts = Compiler.run_opts(spec, opts)

    with :ok <- Compiler.validate_runtime!(spec, opts),
         :ok <- BeamWeaver.Agent.Schema.validate_input(spec.input_schema, input),
         {:ok, compiled} <- compiled_graph(agent_module, opts),
         _runtime <- agent_runtime(agent_module, compiled, opts) do
      Compiled.stream_events(compiled, project_input(input, compiled), opts)
    end
  end

  @spec resume(agent_module(), term(), keyword()) ::
          {:ok, map()} | {:interrupted, map()} | {:error, Error.t()}
  @spec resume(built_agent(), term(), keyword()) ::
          {:ok, map()} | {:interrupted, map()} | {:error, Error.t()}
  def resume(agent, resume, opts \\ [])

  def resume(%Built{} = agent, resume, opts) do
    spec = agent.spec |> Capabilities.apply()
    opts = Compiler.run_opts(spec, opts)

    with :ok <- Compiler.validate_runtime!(spec, opts) do
      case Compiled.resume(agent.compiled, resume, opts) do
        {:ok, state} ->
          with :ok <- BeamWeaver.Agent.Schema.validate_output(spec.output_schema, state) do
            {:ok, state}
          end

        other ->
          other
      end
    end
  end

  def resume(agent_module, resume, opts) when is_atom(agent_module) do
    spec = agent_module.__beam_weaver_agent_spec__() |> Capabilities.apply()
    opts = Compiler.run_opts(spec, opts)

    with :ok <- Compiler.validate_runtime!(spec, opts),
         {:ok, compiled} <- compiled_graph(agent_module, opts),
         _runtime <- agent_runtime(agent_module, compiled, opts) do
      case Compiled.resume(compiled, resume, opts) do
        {:ok, state} ->
          with :ok <- BeamWeaver.Agent.Schema.validate_output(spec.output_schema, state) do
            {:ok, state}
          end

        other ->
          other
      end
    end
  end

  @spec resume_review(agent_module(), term(), keyword()) ::
          {:ok, map()} | {:interrupted, map()} | {:error, Error.t()}
  def resume_review(agent_module, review_or_decisions, opts \\ []) when is_atom(agent_module) do
    resume(agent_module, BeamWeaver.Agent.HITL.resume_value(review_or_decisions), opts)
  end

  @spec get_state(agent_module(), keyword() | map()) ::
          {:ok, map()} | :error | {:error, Error.t()}
  @spec get_state(built_agent(), keyword() | map()) :: {:ok, map()} | :error | {:error, Error.t()}
  def get_state(agent, opts \\ [])

  def get_state(%Built{} = agent, opts) do
    config =
      if is_map(opts) do
        opts
      else
        Keyword.get(opts, :config, %{})
      end

    Compiled.get_state(agent.compiled, config)
  end

  def get_state(agent_module, opts) when is_atom(agent_module) do
    {compile_opts, config} =
      if is_map(opts) do
        {[], opts}
      else
        {opts, Keyword.get(opts, :config, %{})}
      end

    with {:ok, compiled} <- compiled_graph(agent_module, compile_opts) do
      Compiled.get_state(compiled, config)
    end
  end

  @spec compiled_graph(agent_module(), keyword()) :: {:ok, Compiled.t()} | {:error, Error.t()}
  def compiled_graph(agent_module, opts \\ []) do
    spec = agent_module.__beam_weaver_agent_spec__() |> Capabilities.apply()
    compile_opts = Compiler.compile_opts(spec, opts)

    case agent_module.graph() do
      %Compiled{} = compiled ->
        {:ok, compiled}

      %StateGraph{} = graph ->
        Graph.compile(graph, compile_opts)

      other ->
        {:error,
         Error.new(:invalid_agent, "agent graph/0 must return a StateGraph or Compiled graph", %{
           returned: inspect(other)
         })}
    end
  end

  defp agent_runtime(agent_module, %Compiled{} = compiled, opts) do
    %Runtime{
      context: Keyword.get(opts, :context),
      model_opts: Keyword.get(opts, :model_opts, []),
      store: compiled.store,
      checkpointer: compiled.checkpointer,
      cache: compiled.cache,
      config: Keyword.get(opts, :config, %{}),
      graph_name: compiled.name,
      node: inspect(agent_module),
      step: 0,
      stream_writer: fn _value -> :ok end,
      run_id: ID.uuidv7()
    }
  end

  defp built_runtime(%Built{} = agent, opts) do
    %Runtime{
      context: Keyword.get(opts, :context),
      model_opts: Keyword.get(opts, :model_opts, []),
      store: agent.compiled.store,
      checkpointer: agent.compiled.checkpointer,
      cache: agent.compiled.cache,
      config: Keyword.get(opts, :config, %{}),
      graph_name: agent.compiled.name,
      node: to_string(agent.spec.name || "BeamWeaver.Agent.Built"),
      step: 0,
      stream_writer: fn _value -> :ok end,
      run_id: ID.uuidv7()
    }
  end

  defp project_input(input, %Compiled{graph: %{state_schema: state_schema}}),
    do: State.project(input, state_schema)
end
