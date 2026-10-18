Code.require_file("../../support.exs", __DIR__)

# Builds the deep agents in examples/deepagents/ with the live example model.
defmodule BeamWeaver.Examples.DeepAgents.Support do
  @moduledoc false

  alias BeamWeaver.Agent
  alias BeamWeaver.Agent.Middleware.ModelCallLimit
  alias BeamWeaver.Agent.Middleware.ToolCallLimit
  alias BeamWeaver.Examples.Support
  alias BeamWeaver.ExecutionPolicy

  # Live provider calls can be slow, and the tools node runs whole subagent
  # conversations, so every graph node gets four minutes.
  @node_timeout 240_000

  # `recursion_limit` counts graph steps, not model calls. A deep agent takes
  # about seven steps per model turn (middleware hooks, the model, the tools),
  # so this is only a backstop; the call limits stop a looping model.
  @recursion_limit 120

  @doc "Builds an agent with `BeamWeaver.Agent.build/1`, adding call limits and node timeouts."
  def create(opts) do
    opts =
      opts
      |> Keyword.put_new(:recursion_limit, @recursion_limit)
      |> Keyword.update(:middleware, limits(), &(List.wrap(&1) ++ limits()))
      |> Keyword.put_new(:model_opts, max_tokens: 2_048, max_output_tokens: 2_048, timeout: @node_timeout)

    with {:ok, agent} <- Agent.build(opts), do: {:ok, extend_timeout(agent)}
  end

  @doc """
  At most 16 model calls and 24 tool calls per run. Pass them to subagent specs
  too (`middleware: Support.limits()`); a subagent is a separate agent.
  """
  def limits, do: [ModelCallLimit.new(run_limit: 16), ToolCallLimit.new(run_limit: 24), Support.tool_log()]

  def model, do: Support.model()

  defdelegate assert_tools_called!(messages, expected), to: Support
  defdelegate assert_text!(value), to: Support
  defdelegate assert_files!(pattern), to: Support

  @doc "The directory that holds one example's files."
  def root(name), do: Support.tmp_dir(Path.join("deepagents", name))

  @doc "Empties the example's directory and returns its path."
  def fresh_root!(name) do
    root = root(name)
    File.rm_rf!(root)
    File.mkdir_p!(root)
    root
  end

  defp extend_timeout(agent), do: update_in(agent.compiled, &extend_compiled_timeout/1)

  defp extend_compiled_timeout(compiled) do
    graph = extend_graph_timeout(compiled.graph)
    %{compiled | graph: graph, plan: %{compiled.plan | graph: graph}}
  end

  defp extend_graph_timeout(graph) do
    nodes =
      Map.new(graph.nodes, fn {name, spec} ->
        {name, %{spec | timeout: @node_timeout, execution_policy: ExecutionPolicy.new!(timeout: @node_timeout)}}
      end)

    %{graph | nodes: nodes}
  end
end
