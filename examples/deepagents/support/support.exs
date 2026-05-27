defmodule BeamWeaver.Examples.DeepAgents.Support do
  @moduledoc false

  alias BeamWeaver.Agent
  alias BeamWeaver.Config
  alias BeamWeaver.ExecutionPolicy
  alias BeamWeaver.Models
  alias BeamWeaver.Models.FakeChatModel

  @live_node_timeout 30_000

  @live_suffix """
  Example live smoke-test mode is enabled. Complete the user's request with one
  concise sentence. Do not call tools unless absolutely necessary.
  """

  def create(opts) do
    result =
      opts
      |> maybe_add_live_system_prompt()
      |> Keyword.put_new(:model_opts, model_opts())
      |> Agent.build()

    case result do
      {:ok, agent} -> {:ok, maybe_extend_live_timeout(agent)}
      other -> other
    end
  end

  def model(response) do
    if live?() do
      model_id = Config.get([:examples, :deep_agents_model], "openai:gpt-5.4-mini")

      model_opts =
        [
          api_key: Config.get([:openai, :api_key]),
          max_tokens: 96,
          max_output_tokens: 96,
          timeout: 30_000
        ]
        |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)

      case Models.init_chat_model(model_id, model_opts) do
        {:ok, model} -> model
        {:error, error} -> raise ArgumentError, error.message
      end
    else
      %FakeChatModel{response: response}
    end
  end

  def model_opts do
    if live?(), do: [tool_choice: "none", max_tokens: 96, max_output_tokens: 96], else: []
  end

  def live? do
    truthy?(Config.get([:examples, :deep_agents_live?]))
  end

  defp truthy?(true), do: true

  defp truthy?(value) when is_binary(value),
    do: String.downcase(value) in ["1", "true", "yes", "on"]

  defp truthy?(_value), do: false

  defp maybe_add_live_system_prompt(opts) do
    if live?() do
      Keyword.update(opts, :system_prompt, @live_suffix, fn
        nil -> @live_suffix
        prompt -> to_string(prompt) <> "\n\n" <> @live_suffix
      end)
    else
      opts
    end
  end

  defp maybe_extend_live_timeout(agent) do
    if live?() do
      update_in(agent.compiled, &extend_compiled_timeout/1)
    else
      agent
    end
  end

  defp extend_compiled_timeout(compiled) do
    graph = extend_graph_timeout(compiled.graph)
    plan = %{compiled.plan | graph: graph}

    %{compiled | graph: graph, plan: plan}
  end

  defp extend_graph_timeout(graph) do
    nodes =
      Map.new(graph.nodes, fn {name, spec} ->
        spec = %{
          spec
          | timeout: @live_node_timeout,
            execution_policy: ExecutionPolicy.new!(timeout: @live_node_timeout)
        }

        {name, spec}
      end)

    %{graph | nodes: nodes}
  end
end
