defmodule BeamWeaver.Graph.Nodes.ToolNode do
  @moduledoc """
  Graph node that executes model tool calls.

  The node accepts normal graph state (`%{messages: [...]}`), a raw message
  list, or a raw tool-call list. It returns tool messages in the same shape a
  graph reducer can append to state. Tools may also return graph commands when
  the command update includes the tool message required by the original call.
  """

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Graph.Command
  alias BeamWeaver.Graph.Nodes.ToolNode.Execution
  alias BeamWeaver.Graph.Nodes.ToolNode.Input
  alias BeamWeaver.Graph.Nodes.ToolNode.Output

  defstruct tools: %{},
            handle_errors: true,
            timeout: 5_000,
            wrap_tool_call: [],
            messages_key: :messages

  @type t :: %__MODULE__{
          tools: %{String.t() => term()},
          handle_errors: boolean() | atom() | [atom()] | String.t() | function(),
          timeout: timeout(),
          wrap_tool_call: [term()],
          messages_key: atom() | String.t()
        }

  @spec new([term()], keyword()) :: t()
  def new(tools, opts \\ []) when is_list(tools) do
    %__MODULE__{
      tools: Map.new(tools, fn tool -> {Tool.name(tool), tool} end),
      handle_errors: Keyword.get(opts, :handle_errors, true),
      timeout: Keyword.get(opts, :timeout, 5_000),
      wrap_tool_call: Keyword.get(opts, :wrap_tool_call, []),
      messages_key: Keyword.get(opts, :messages_key, :messages)
    }
  end

  @doc """
  Returns the tool registry used by a tool node, keyed by tool name.

  The helper accepts either a `%ToolNode{}` or a raw tool list so callers can
  inspect the same native registry shape before and after node construction.
  """
  @spec tools_by_name(t() | [term()]) :: %{String.t() => term()}
  def tools_by_name(%__MODULE__{tools: tools}), do: tools

  def tools_by_name(tools) when is_list(tools),
    do: Map.new(tools, fn tool -> {Tool.name(tool), tool} end)

  @doc """
  Formats a tool return value into model-visible tool message content.

  Binaries are preserved, maps and lists are JSON encoded with UTF-8 text left
  unescaped by BeamWeaver.JSON, and scalar values use Elixir's normal string conversion.
  """
  @spec msg_content_output(term()) :: String.t()
  def msg_content_output(value), do: Output.format(value)

  @spec invoke(t(), term(), term()) :: map() | [Message.t()] | Command.t() | {:error, Error.t()}
  def invoke(%__MODULE__{} = node, input, runtime \\ nil) do
    Execution.invoke(node, input, runtime)
  end

  def tools_condition(input, messages_key \\ :messages)

  def tools_condition(input, messages_key), do: Input.condition(input, messages_key)
end
