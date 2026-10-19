defmodule BeamWeaver.Graph.IntoNode do
  @moduledoc false

  alias BeamWeaver.Core.ChatModel
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Graph.Compiled

  # What a node's callable runs as.
  @spec to_node(term()) :: {:ok, map()} | {:error, Error.t()}
  def to_node(fun) when is_function(fun) do
    {:arity, arity} = :erlang.fun_info(fun, :arity)

    if arity in [1, 2] do
      {:ok, %{fun: fun, kind: :function, metadata: %{arity: arity}}}
    else
      {:error,
       Error.new(:invalid_graph, "node function must accept state or state/runtime", %{callable: "function/#{arity}"})}
    end
  end

  # A module that implements `BeamWeaver.Graph`, such as a graph or agent
  # module, also exports `invoke/2`, with call options as its second argument,
  # so it is recognised first: its graph runs as a subgraph.
  def to_node(module) when is_atom(module) do
    cond do
      BeamWeaver.Behaviour.implemented_by?(module, BeamWeaver.Graph) ->
        {:ok, %{fun: module, kind: :subgraph, metadata: %{module: module}}}

      BeamWeaver.Behaviour.exported?(module, :invoke, 2) ->
        {:ok, %{fun: module, kind: :module, metadata: %{module: module}}}

      true ->
        {:error, Error.new(:invalid_graph, "node module must implement invoke/2", %{module: inspect(module)})}
    end
  end

  def to_node(%Compiled{} = compiled), do: {:ok, %{fun: compiled, kind: :subgraph, metadata: %{graph: compiled.name}}}

  def to_node(%Tool{} = tool), do: {:ok, %{fun: tool_node(tool), kind: :tool, metadata: %{tool: tool.name}}}

  def to_node(%{__struct__: module} = struct) do
    cond do
      BeamWeaver.Behaviour.implemented_by?(module, ChatModel) ->
        {:ok, %{fun: model_node(struct), kind: :model, metadata: %{module: module}}}

      function_exported?(module, :invoke, 3) or function_exported?(module, :invoke, 2) ->
        {:ok, %{fun: struct, kind: :struct, metadata: %{module: module}}}

      true ->
        {:error, Error.new(:invalid_graph, "node struct is not executable", %{module: inspect(module)})}
    end
  end

  def to_node(other),
    do: {:error, Error.new(:invalid_graph, "node value is not executable", %{callable: inspect(other)})}

  defp model_node(model) do
    fn state, _runtime ->
      messages = Map.get(state, :messages, Map.get(state, "messages", []))

      with {:ok, message} <- ChatModel.invoke(model, messages), do: %{messages: [message]}
    end
  end

  defp tool_node(tool) do
    fn state, runtime ->
      input = Map.get(state, :input, Map.get(state, "input", state))

      with {:ok, value} <- Tool.invoke(tool, input, runtime: runtime), do: %{tool_result: value}
    end
  end
end
