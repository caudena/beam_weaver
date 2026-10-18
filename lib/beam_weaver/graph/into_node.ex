defprotocol BeamWeaver.Graph.IntoNode do
  @moduledoc false

  @fallback_to_any true

  @spec to_node(term(), String.t(), keyword()) ::
          {:ok, map()} | {:error, BeamWeaver.Core.Error.t()}
  def to_node(callable, name, opts)
end

defimpl BeamWeaver.Graph.IntoNode, for: Function do
  def to_node(fun, _name, _opts) do
    {:arity, arity} = :erlang.fun_info(fun, :arity)

    if arity in [1, 2] do
      {:ok, %{fun: fun, kind: :function, metadata: %{arity: arity}}}
    else
      {:error,
       BeamWeaver.Core.Error.new(
         :invalid_graph,
         "node function must accept state or state/runtime",
         %{
           callable: "function/#{arity}"
         }
       )}
    end
  end
end

defimpl BeamWeaver.Graph.IntoNode, for: Atom do
  # A module that implements `BeamWeaver.Graph`, such as a graph or agent
  # module, also exports `invoke/2`, with call options as its second argument,
  # so it is recognised first: its graph runs as a subgraph.
  def to_node(module, _name, _opts) do
    cond do
      BeamWeaver.Behaviour.implemented_by?(module, BeamWeaver.Graph) ->
        {:ok, %{fun: module, kind: :subgraph, metadata: %{module: module}}}

      BeamWeaver.Behaviour.exported?(module, :invoke, 2) ->
        {:ok, %{fun: module, kind: :module, metadata: %{module: module}}}

      true ->
        {:error,
         BeamWeaver.Core.Error.new(:invalid_graph, "node module must implement invoke/2", %{
           module: inspect(module)
         })}
    end
  end
end

defimpl BeamWeaver.Graph.IntoNode, for: Any do
  alias BeamWeaver.Core.ChatModel
  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Graph.Compiled

  def to_node(%Compiled{} = compiled, _name, _opts),
    do: {:ok, %{fun: compiled, kind: :subgraph, metadata: %{graph: compiled.name}}}

  def to_node(%Tool{} = tool, _name, _opts),
    do: {:ok, %{fun: tool_node(tool), kind: :tool, metadata: %{tool: tool.name}}}

  def to_node(%{__struct__: module} = struct, _name, _opts) do
    cond do
      chat_model?(module) ->
        {:ok, %{fun: model_node(struct), kind: :model, metadata: %{module: module}}}

      function_exported?(module, :invoke, 3) or function_exported?(module, :invoke, 2) ->
        {:ok, %{fun: struct, kind: :struct, metadata: %{module: module}}}

      true ->
        {:error,
         BeamWeaver.Core.Error.new(:invalid_graph, "node struct is not executable", %{
           module: inspect(module)
         })}
    end
  end

  def to_node(other, _name, _opts),
    do:
      {:error,
       BeamWeaver.Core.Error.new(:invalid_graph, "node value is not executable", %{
         callable: inspect(other)
       })}

  defp chat_model?(module), do: BeamWeaver.Behaviour.implemented_by?(module, ChatModel)

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
