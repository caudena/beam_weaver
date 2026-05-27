defmodule BeamWeaver.Graph.Errors do
  @moduledoc """
  Native graph error helpers.

  LangGraph exposes many graph failures as Python exception classes. BeamWeaver
  keeps recoverable graph failures as tagged `%BeamWeaver.Core.Error{}` values
  and uses this module only to centralize graph error-code metadata and common
  constructors.
  """

  alias BeamWeaver.Core.Error

  @error_codes %{
    recursion_limit: "GRAPH_RECURSION_LIMIT",
    invalid_concurrent_update: "INVALID_CONCURRENT_GRAPH_UPDATE",
    invalid_node_return: "INVALID_GRAPH_NODE_RETURN_VALUE",
    multiple_subgraphs: "MULTIPLE_SUBGRAPHS",
    invalid_chat_history: "INVALID_CHAT_HISTORY"
  }

  @doc "Returns the graph troubleshooting error codes known to BeamWeaver."
  @spec error_codes() :: %{atom() => String.t()}
  def error_codes, do: @error_codes

  @doc """
  Appends the LangGraph troubleshooting URL for a graph error code.
  """
  @spec create_message(String.t(), atom() | String.t()) :: String.t()
  def create_message(message, error_code) when is_binary(message) do
    code = error_code_value(error_code)

    message <>
      "\nFor troubleshooting, visit: https://docs.langchain.com/oss/python/langgraph/errors/" <>
      code
  end

  @spec new(atom(), String.t(), map()) :: Error.t()
  def new(type, message, details \\ %{}), do: Error.new(type, message, details)

  @spec recursion_limit(pos_integer(), non_neg_integer()) :: Error.t()
  def recursion_limit(limit, step) do
    Error.new(
      :recursion_limit,
      create_message("graph recursion limit reached", :recursion_limit),
      %{limit: limit, step: step, code: @error_codes.recursion_limit}
    )
  end

  @spec invalid_concurrent_update(map()) :: Error.t()
  def invalid_concurrent_update(details \\ %{}) do
    Error.new(
      :invalid_update,
      create_message("invalid concurrent graph update", :invalid_concurrent_update),
      Map.put(details, :code, @error_codes.invalid_concurrent_update)
    )
  end

  @spec invalid_node_return(atom() | String.t(), term()) :: Error.t()
  def invalid_node_return(node, value) do
    Error.new(
      :invalid_node_return,
      create_message("graph node returned an invalid value", :invalid_node_return),
      %{node: to_string(node), value: inspect(value), code: @error_codes.invalid_node_return}
    )
  end

  @spec multiple_subgraphs(map()) :: Error.t()
  def multiple_subgraphs(details \\ %{}) do
    Error.new(
      :multiple_subgraphs,
      create_message("multiple subgraphs matched the requested namespace", :multiple_subgraphs),
      Map.put(details, :code, @error_codes.multiple_subgraphs)
    )
  end

  @spec invalid_chat_history(map()) :: Error.t()
  def invalid_chat_history(details \\ %{}) do
    Error.new(
      :invalid_chat_history,
      create_message("invalid chat history", :invalid_chat_history),
      Map.put(details, :code, @error_codes.invalid_chat_history)
    )
  end

  @spec graph_interrupt([term()]) :: Error.t()
  def graph_interrupt(interrupts \\ []) do
    Error.new(:graph_interrupt, "graph interrupted", %{interrupts: List.wrap(interrupts)})
  end

  @spec graph_drained(String.t()) :: Error.t()
  def graph_drained(reason \\ "shutdown") do
    Error.new(:graph_drained, "graph drained: #{reason}", %{reason: reason})
  end

  @spec parent_command(term()) :: Error.t()
  def parent_command(command) do
    Error.new(:parent_command, "parent command escaped the root graph", %{command: command})
  end

  @spec task_not_found(term()) :: Error.t()
  def task_not_found(task_id) do
    Error.new(:task_not_found, "graph task was not found", %{task_id: task_id})
  end

  @spec node_error(atom() | String.t(), Error.t()) :: Error.t()
  def node_error(node, %Error{} = error) do
    Error.new(:node_error, "node #{node} failed", %{node: to_string(node), error: error})
  end

  @spec node_timeout(atom() | String.t(), number(), keyword() | map()) :: Error.t()
  def node_timeout(node, elapsed, opts) when is_list(opts),
    do: node_timeout(node, elapsed, Map.new(opts))

  def node_timeout(node, elapsed, opts) when is_map(opts) do
    kind = Map.get(opts, :kind) || Map.get(opts, "kind")
    idle_timeout = Map.get(opts, :idle_timeout) || Map.get(opts, "idle_timeout")
    run_timeout = Map.get(opts, :run_timeout) || Map.get(opts, "run_timeout")
    timeout = if kind in [:idle, "idle"], do: idle_timeout, else: run_timeout

    Error.new(:node_timeout, node_timeout_message(node, elapsed, kind, timeout), %{
      node: to_string(node),
      elapsed: elapsed,
      kind: normalize_timeout_kind(kind),
      idle_timeout: idle_timeout,
      run_timeout: run_timeout,
      timeout: timeout
    })
  end

  defp node_timeout_message(node, elapsed, kind, timeout) when kind in [:idle, "idle"] do
    "node #{inspect(to_string(node))} exceeded its idle timeout of #{format_seconds(timeout)} " <>
      "without making progress (elapsed: #{format_seconds(elapsed)})"
  end

  defp node_timeout_message(node, elapsed, _kind, timeout) do
    "node #{inspect(to_string(node))} exceeded its run timeout of #{format_seconds(timeout)} " <>
      "(elapsed: #{format_seconds(elapsed)})"
  end

  defp normalize_timeout_kind(kind) when kind in [:idle, "idle"], do: :idle
  defp normalize_timeout_kind(_kind), do: :run

  defp format_seconds(value) when is_number(value),
    do: :io_lib.format("~.3fs", [value]) |> to_string()

  defp format_seconds(nil), do: "unspecified"
  defp format_seconds(value), do: to_string(value)

  defp error_code_value(error_code) when is_atom(error_code),
    do: Map.fetch!(@error_codes, error_code)

  defp error_code_value(error_code) when is_binary(error_code), do: error_code
end
