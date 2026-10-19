defmodule BeamWeaver.Agent.Builder do
  @moduledoc false

  alias BeamWeaver.Agent.Built
  alias BeamWeaver.Agent.Capabilities
  alias BeamWeaver.Agent.Compiler
  alias BeamWeaver.Agent.Spec
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Graph

  # The options `build/1` takes, named like the declarations of an agent module.
  @options Map.keys(%Spec{}) -- [:__struct__, :module, :execution_mode]

  @option_names Map.new(@options, &{Atom.to_string(&1), &1})

  @spec build(keyword() | map()) :: {:ok, Built.t()} | {:error, Error.t()}
  def build(opts) when is_list(opts) or is_map(opts) do
    with {:ok, spec} <- validate(opts),
         {:ok, compiled} <- Graph.compile(Compiler.compile_graph(spec), Compiler.compile_opts(spec, [])) do
      {:ok, %Built{spec: spec, compiled: compiled}}
    end
  end

  # An agent module's declarations, evaluated now, under the names of the
  # options above: what `build/1` takes to build the same agent. Read in a
  # module attribute, the agent may still be compiling: `ensure_compiled/1`
  # waits for it there, and only loads it at runtime.
  @spec declarations(module()) :: map()
  def declarations(module) when is_atom(module) do
    unless match?({:module, _}, Code.ensure_compiled(module)) and
             function_exported?(module, :__beam_weaver_agent_spec__, 0),
           do: raise(ArgumentError, "#{inspect(module)} is not an agent module: `use BeamWeaver.Agent` in it")

    module.__beam_weaver_agent_spec__() |> Map.from_struct() |> Map.take(@options)
  end

  # Checks the options as `build/1` does and returns the spec it would
  # compile, without compiling the graph. A parent agent checks its subagents
  # this way when it is built; a `task` call builds the one it runs.
  # `validate_opts` go to `Compiler.validate/2`.
  @spec validate(keyword() | map(), keyword()) :: {:ok, Spec.t()} | {:error, Error.t()}
  def validate(opts, validate_opts \\ []) when is_list(opts) or is_map(opts) do
    with :ok <- validate_options(opts),
         {:ok, spec} <- runtime_spec(opts),
         {:ok, spec} <- Capabilities.apply(spec),
         :ok <- Compiler.validate(spec, validate_opts) do
      {:ok, spec}
    end
  end

  defp validate_options(opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      validate_option_names(Keyword.keys(opts))
    else
      {:error, Error.new(:invalid_agent, "BeamWeaver.Agent.build/1 takes a keyword list or a map")}
    end
  end

  defp validate_options(opts) when is_map(opts), do: validate_option_names(Map.keys(opts))

  defp validate_option_names(names) do
    case Enum.reject(names, &known_option?/1) do
      [] ->
        :ok

      unknown ->
        {:error,
         Error.new(
           :invalid_agent,
           "unknown BeamWeaver.Agent.build/1 options: #{Enum.map_join(unknown, ", ", &to_string/1)}",
           %{options: unknown}
         )}
    end
  end

  defp known_option?(key) when is_atom(key), do: key in @options
  defp known_option?(key) when is_binary(key), do: Map.has_key?(@option_names, key)
  defp known_option?(_key), do: false

  defp runtime_spec(opts) do
    if is_nil(option(opts, :model)) do
      {:error,
       Error.new(:invalid_agent, "BeamWeaver.Agent.build/1 requires a :model option", %{
         option: :model
       })}
    else
      {:ok, Spec.from_dsl_attrs(Built, Map.new(@options, &{&1, option(opts, &1)}))}
    end
  end

  defp option(opts, key) when is_list(opts), do: Keyword.get(opts, key)
  defp option(opts, key) when is_map(opts), do: Map.get(opts, key, Map.get(opts, Atom.to_string(key)))
end
