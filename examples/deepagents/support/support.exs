Code.require_file("../../support.exs", __DIR__)

defmodule BeamWeaver.Examples.DeepAgents.Support do
  @moduledoc false

  alias BeamWeaver.Agent
  alias BeamWeaver.Agent.Middleware.ToolSelection
  alias BeamWeaver.ExecutionPolicy
  alias BeamWeaver.Examples.Support

  @node_timeout 120_000

  @concise_suffix """
  This is a live provider smoke run. Do not call tools. Answer the user's request
  directly in one concise sentence using the context already provided.
  """

  def create(opts) do
    opts =
      opts
      |> add_concise_prompt()
      |> disable_visible_tools()
      |> Keyword.put_new(:model_opts, default_model_opts())

    case Agent.build(opts) do
      {:ok, agent} -> {:ok, extend_timeout(agent)}
      other -> other
    end
  end

  def model, do: Support.model()

  defp default_model_opts,
    do: [max_tokens: 2_048, max_output_tokens: 2_048, timeout: @node_timeout]

  defp add_concise_prompt(opts) do
    Keyword.update(opts, :system_prompt, @concise_suffix, fn
      nil -> @concise_suffix
      prompt -> to_string(prompt) <> "\n\n" <> @concise_suffix
    end)
  end

  defp disable_visible_tools(opts) do
    Keyword.update(opts, :middleware, [ToolSelection.new(allow: [])], fn middleware ->
      List.wrap(middleware) ++ [ToolSelection.new(allow: [])]
    end)
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
