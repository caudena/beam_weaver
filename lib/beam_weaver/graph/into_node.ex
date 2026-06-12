defprotocol BeamWeaver.Graph.IntoNode do
  @moduledoc """
  Converts executable values into explicit graph node specs.
  """

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
  def to_node(module, _name, _opts) do
    cond do
      function_exported?(module, :invoke, 2) ->
        {:ok, %{fun: module, kind: :module, metadata: %{module: module}}}

      agent_module?(module) ->
        {:ok, %{fun: module, kind: :agent, metadata: %{module: module}}}

      true ->
        {:error,
         BeamWeaver.Core.Error.new(:invalid_graph, "node module must implement invoke/2", %{
           module: inspect(module)
         })}
    end
  end

  defp agent_module?(module) do
    function_exported?(module, :compile, 1) or function_exported?(module, :compiled_graph, 0)
  end
end

defimpl BeamWeaver.Graph.IntoNode, for: Any do
  alias BeamWeaver.Core.ChatModel
  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Graph.Compiled
  alias BeamWeaver.Runnable

  def to_node(%Compiled{} = compiled, _name, _opts),
    do: {:ok, %{fun: compiled, kind: :subgraph, metadata: %{graph: compiled.name}}}

  def to_node(%Tool{} = tool, _name, _opts),
    do: {:ok, %{fun: tool_node(tool), kind: :tool, metadata: %{tool: tool.name}}}

  def to_node(%{__struct__: module} = struct, _name, _opts) do
    cond do
      chat_model?(module) ->
        {:ok, %{fun: model_node(struct), kind: :model, metadata: %{module: module}}}

      runnable?(module) ->
        {:ok, %{fun: runnable_node(struct), kind: :runnable, metadata: %{module: module}}}

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

  defp runnable?(module), do: implements_behaviour?(module, Runnable)

  defp chat_model?(module), do: implements_behaviour?(module, ChatModel)

  defp implements_behaviour?(module, behaviour) do
    Code.ensure_loaded?(module) and
      module
      |> module_behaviours()
      |> Enum.member?(behaviour)
  end

  defp module_behaviours(module) do
    module.module_info(:attributes)
    |> Keyword.take([:behaviour, :behavior])
    |> Keyword.values()
    |> List.flatten()
  rescue
    _ -> []
  end

  defp runnable_node(runnable) do
    fn state, _runtime ->
      case Runnable.invoke(runnable, state) do
        {:ok, value} -> value
        {:error, error} -> {:error, error}
      end
    end
  end

  defp model_node(model) do
    fn state, _runtime ->
      messages = Map.get(state, :messages, Map.get(state, "messages", []))

      case ChatModel.invoke(model, messages) do
        {:ok, message} -> %{messages: [message]}
        {:error, error} -> {:error, error}
      end
    end
  end

  defp tool_node(tool) do
    fn state, runtime ->
      input = Map.get(state, :input, Map.get(state, "input", state))

      case Tool.invoke(tool, input, runtime: runtime) do
        {:ok, value} -> %{tool_result: value}
        {:error, error} -> {:error, error}
      end
    end
  end
end
