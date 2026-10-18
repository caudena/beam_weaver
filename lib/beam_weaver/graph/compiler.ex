defmodule BeamWeaver.Graph.Compiler do
  @moduledoc false

  alias BeamWeaver.Cache
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Graph.Compiled
  alias BeamWeaver.Graph.Execution.Options
  alias BeamWeaver.Graph.Execution.Plan
  alias BeamWeaver.Graph.StateGraph
  alias BeamWeaver.Graph.Validation

  @spec compile(StateGraph.t(), keyword()) :: {:ok, Compiled.t()} | {:error, Error.t()}
  def compile(%StateGraph{} = graph, opts) do
    with :ok <-
           Validation.validate(graph, validate_static: Keyword.get(opts, :validate_static, false)),
         {:ok, cache} <- normalize_cache(Keyword.get(opts, :cache), graph),
         {:ok, checkpointer, checkpoint_scope} <-
           normalize_checkpointer(Keyword.get(opts, :checkpointer)) do
      {:ok,
       %Compiled{
         name: Keyword.get(opts, :name, graph.name) |> to_string(),
         graph: graph,
         plan: Plan.from(graph),
         checkpointer: checkpointer,
         checkpoint_scope: checkpoint_scope,
         store: Keyword.get(opts, :store),
         interrupt_before: normalize_interrupts(Keyword.get(opts, :interrupt_before, [])),
         interrupt_after: normalize_interrupts(Keyword.get(opts, :interrupt_after, [])),
         step_timeout: Options.normalize_timeout(Keyword.get(opts, :step_timeout, :infinity)),
         run_timeout: Options.normalize_timeout(Keyword.get(opts, :run_timeout, :infinity)),
         debug: Keyword.get(opts, :debug, false),
         cache: cache
       }}
    end
  end

  defp normalize_interrupts(:all), do: :all
  defp normalize_interrupts("*"), do: :all
  defp normalize_interrupts(nodes) when is_list(nodes), do: MapSet.new(nodes, &normalize_node/1)
  defp normalize_interrupts(node), do: MapSet.new([normalize_node(node)])

  defp normalize_cache(true, graph),
    do: {:error, Cache.explicit_required_error(%{graph: graph.name})}

  defp normalize_cache(cache, graph) when cache in [nil, false, %{}] do
    case cached_nodes(graph) do
      [] -> {:ok, nil}
      nodes -> {:error, Cache.explicit_required_error(%{graph: graph.name, nodes: nodes})}
    end
  end

  defp normalize_cache(cache, _graph) do
    if Cache.adapter?(cache) do
      {:ok, cache}
    else
      {:error,
       Error.new(:invalid_cache, "graph cache must be a BeamWeaver.Cache adapter", %{
         cache: inspect(cache)
       })}
    end
  end

  defp normalize_checkpointer(nil), do: {:ok, nil, :inherit}
  defp normalize_checkpointer(true), do: {:ok, nil, :shared}
  defp normalize_checkpointer(:inherit), do: {:ok, nil, :inherit}
  defp normalize_checkpointer(:shared), do: {:ok, nil, :shared}
  defp normalize_checkpointer(false), do: {:ok, nil, :disabled}
  defp normalize_checkpointer(:disabled), do: {:ok, nil, :disabled}

  defp normalize_checkpointer(checkpointer) do
    if is_struct(checkpointer) and saver?(checkpointer.__struct__) do
      {:ok, checkpointer, :local}
    else
      {:error,
       Error.new(
         :invalid_checkpointer,
         "graph checkpointer must implement BeamWeaver.Checkpoint.Saver",
         %{checkpointer: inspect(checkpointer)}
       )}
    end
  end

  defp saver?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :get_tuple, 2) and
      function_exported?(module, :list, 3) and function_exported?(module, :put, 5) and
      function_exported?(module, :put_writes, 5)
  end

  defp cached_nodes(graph), do: Enum.sort(for {name, spec} <- graph.nodes, spec.cache not in [false, nil], do: name)

  defp normalize_node(:__start__), do: "__start__"
  defp normalize_node(:start), do: "__start__"
  defp normalize_node("START"), do: "__start__"
  defp normalize_node("start"), do: "__start__"
  defp normalize_node(:__end__), do: "__end__"
  defp normalize_node(:end), do: "__end__"
  defp normalize_node("END"), do: "__end__"
  defp normalize_node("end"), do: "__end__"
  defp normalize_node(node), do: to_string(node)
end
