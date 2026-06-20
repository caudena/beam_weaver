Code.require_file("../../support.exs", __DIR__)

defmodule BeamWeaver.Examples.DeepAgents.Support do
  @moduledoc false

  alias BeamWeaver.Agent
  alias BeamWeaver.ExecutionPolicy
  alias BeamWeaver.Examples.Support

  @node_timeout 30_000

  @concise_suffix """
  Complete the user's request with one concise sentence. Do not call tools unless
  absolutely necessary.
  """

  def create(opts) do
    opts =
      opts
      |> add_concise_prompt()
      |> Keyword.put_new(:model_opts, tool_choice: "none", max_tokens: 256, max_output_tokens: 256)

    case Agent.build(opts) do
      {:ok, agent} -> {:ok, extend_timeout(agent)}
      other -> other
    end
  end

  def model, do: Support.model()

  defp add_concise_prompt(opts) do
    Keyword.update(opts, :system_prompt, @concise_suffix, fn
      nil -> @concise_suffix
      prompt -> to_string(prompt) <> "\n\n" <> @concise_suffix
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
