defmodule BeamWeaver.Agent.Builder do
  @moduledoc """
  Builds runtime-configured agents.

  Module-defined agents remain the canonical API for application code. This
  module keeps dynamic agent construction separate from the DSL macro surface.
  """

  alias BeamWeaver.Agent.Built
  alias BeamWeaver.Agent.Capabilities
  alias BeamWeaver.Agent.Compiler
  alias BeamWeaver.Agent.Spec
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Graph

  @spec build(keyword() | map()) :: {:ok, Built.t()} | {:error, Error.t()}
  def build(opts) when is_list(opts) or is_map(opts) do
    with {:ok, spec} <- runtime_spec(opts),
         spec <- Capabilities.apply(spec),
         graph <- Compiler.compile_graph(spec),
         {:ok, compiled} <- Graph.compile(graph, Compiler.compile_opts(spec, [])) do
      {:ok, %Built{spec: spec, compiled: compiled}}
    end
  end

  defp runtime_spec(opts) do
    if is_nil(option(opts, :model)) do
      {:error,
       Error.new(:invalid_agent, "BeamWeaver.Agent.build/1 requires a :model option", %{
         option: :model
       })}
    else
      {:ok,
       %Spec{
         module: Built,
         name: option(opts, :name, "BeamWeaver.Agent.Built"),
         model: option(opts, :model),
         model_opts: option(opts, :model_opts, []),
         tools: List.wrap(option(opts, :tools, [])),
         validate_tools: option(opts, :validate_tools, false),
         middleware: List.wrap(option(opts, :middleware, [])),
         system_prompt: option(opts, :system_prompt),
         response_format: option(opts, :response_format),
         checkpointer: option(opts, :checkpointer),
         store: option(opts, :store),
         cache: option(opts, :cache),
         filesystem: option(opts, :filesystem, option(opts, :backend)),
         filesystem_permissions: option(opts, :filesystem_permissions, option(opts, :permissions)),
         skills: option(opts, :skills),
         memory: option(opts, :memory),
         subagents: option(opts, :subagents),
         async_subagents: option(opts, :async_subagents),
         compact_conversation: option(opts, :compact_conversation),
         overflow_recovery: option(opts, :overflow_recovery, option(opts, :overflow_clip)),
         prompt_caching: option(opts, :prompt_caching),
         exclude_tools: option(opts, :exclude_tools),
         tool_descriptions: option(opts, :tool_descriptions),
         interrupt_on: option(opts, :interrupt_on),
         context_schema: option(opts, :context_schema),
         input_schema: option(opts, :input_schema),
         output_schema: option(opts, :output_schema),
         interrupt_before: List.wrap(option(opts, :interrupt_before, [])),
         interrupt_after: List.wrap(option(opts, :interrupt_after, [])),
         debug: option(opts, :debug, false),
         recursion_limit: option(opts, :recursion_limit)
       }}
    end
  end

  defp option(opts, key, default \\ nil)

  defp option(opts, key, default) when is_list(opts) do
    Keyword.get(opts, key, default)
  end

  defp option(opts, key, default) when is_map(opts) do
    Map.get(opts, key, Map.get(opts, to_string(key), default))
  end
end
