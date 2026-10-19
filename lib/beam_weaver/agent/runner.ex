defmodule BeamWeaver.Agent.Runner do
  @moduledoc false

  alias BeamWeaver.Agent.Built
  alias BeamWeaver.Agent.Capabilities
  alias BeamWeaver.Agent.Compiler
  alias BeamWeaver.Agent.Schema
  alias BeamWeaver.Agent.Spec
  alias BeamWeaver.Agent.State
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Graph
  alias BeamWeaver.Graph.Command
  alias BeamWeaver.Graph.Compiled
  alias BeamWeaver.Graph.ModuleRunner

  @type input :: map()
  @type agent_module :: module()
  @type built_agent :: Built.t()

  @spec invoke(agent_module() | built_agent(), input(), keyword()) ::
          {:ok, map()} | {:interrupted, map()} | {:error, Error.t()}
  def invoke(agent, input, opts) when is_map(input) do
    with {:ok, spec, compiled, opts} <- prepare(agent, opts),
         :ok <- validate_input(spec, input, compiled, opts) do
      compiled
      |> Compiled.invoke(project_input(input, compiled), opts)
      |> validate_output(spec)
    end
  end

  @spec stream_events(agent_module() | built_agent(), input(), keyword()) ::
          {:ok, Enumerable.t()} | {:interrupted, map()} | {:error, Error.t()}
  def stream_events(agent, input, opts) when is_map(input) do
    with {:ok, spec, compiled, opts} <- prepare(agent, opts),
         :ok <- validate_input(spec, input, compiled, opts) do
      Compiled.stream_events(compiled, project_input(input, compiled), opts)
    end
  end

  @spec resume(agent_module() | built_agent(), term(), keyword()) ::
          {:ok, map()} | {:interrupted, map()} | {:error, Error.t()}
  def resume(agent, resume, opts) do
    with {:ok, spec, compiled, opts} <- prepare(agent, opts) do
      compiled
      |> Compiled.resume(resume, opts)
      |> validate_output(spec)
    end
  end

  @spec resume_review(agent_module() | built_agent(), term(), keyword()) ::
          {:ok, map()} | {:interrupted, map()} | {:error, Error.t()}
  def resume_review(agent, review_or_decisions, opts) do
    resume(agent, BeamWeaver.Agent.HITL.resume_value(review_or_decisions), opts)
  end

  @spec get_state(agent_module() | built_agent(), keyword()) :: {:ok, map()} | :error | {:error, Error.t()}
  def get_state(agent, opts) when is_list(opts) do
    with {:ok, spec} <- applied_spec(agent),
         {:ok, compiled} <- compiled(agent, spec, opts) do
      Compiled.get_state(compiled, Keyword.get(opts, :config, %{}))
    end
  end

  @spec compiled_graph(agent_module(), keyword()) :: {:ok, Compiled.t()} | {:error, Error.t()}
  def compiled_graph(agent_module, opts) when is_atom(agent_module) do
    with {:ok, spec} <- applied_spec(agent_module),
         :ok <- validate(agent_module, spec),
         do: compiled(agent_module, spec, opts)
  end

  # Resolves the agent's spec, run options, and compiled graph once per call.
  defp prepare(agent, opts) do
    with {:ok, spec} <- applied_spec(agent),
         :ok <- validate(agent, spec),
         {:ok, opts} <- Compiler.run_opts(spec, opts),
         {:ok, compiled} <- compiled(agent, spec, opts) do
      {:ok, spec, compiled, opts}
    end
  end

  defp applied_spec(%Built{spec: spec}), do: {:ok, spec}

  defp applied_spec(agent_module) when is_atom(agent_module) do
    spec = agent_module.__beam_weaver_agent_spec__()
    ModuleRunner.warn_on_new_storage(agent_module, Map.take(spec, [:checkpointer, :store]))
    Capabilities.apply(spec)
  end

  # `build/1` checked a built agent. An agent module's declarations are
  # checked on its first call, including each subagent as a `task` call
  # would build it.
  defp validate(%Built{}, _spec), do: :ok
  defp validate(agent_module, spec) when is_atom(agent_module), do: Compiler.validate_module(spec)

  # A built agent is compiled with its build options. A call that brings its
  # own checkpointer, store, cache or breakpoints compiles the same graph with
  # them, as an agent module does on every call.
  defp compiled(%Built{compiled: compiled}, spec, opts) do
    if Compiler.graph_opts?(opts),
      do: Graph.compile(compiled.graph, Compiler.compile_opts(spec, opts)),
      else: {:ok, compiled}
  end

  defp compiled(agent_module, spec, opts) when is_atom(agent_module) do
    spec
    |> Compiler.compile_graph()
    |> Graph.compile(Compiler.compile_opts(spec, opts))
  end

  # The input schema checks new input. A `Command`, which resumes or updates
  # the thread, brings none, and neither does an empty input on a thread with
  # saved state, which continues it.
  defp validate_input(%Spec{input_schema: nil}, _input, _compiled, _opts), do: :ok
  defp validate_input(_spec, %Command{}, _compiled, _opts), do: :ok

  defp validate_input(spec, input, compiled, opts) when map_size(input) == 0 do
    case Compiled.get_state(compiled, Keyword.get(opts, :config, %{})) do
      {:ok, _snapshot} -> :ok
      _none -> Schema.validate_input(spec.input_schema, input)
    end
  end

  defp validate_input(spec, input, _compiled, _opts), do: Schema.validate_input(spec.input_schema, input)

  defp validate_output({:ok, state} = result, spec) do
    with :ok <- Schema.validate_output(spec.output_schema, state), do: result
  end

  defp validate_output(result, _spec), do: result

  defp project_input(input, %Compiled{graph: %{state_schema: state_schema}}),
    do: State.project(input, state_schema)
end
