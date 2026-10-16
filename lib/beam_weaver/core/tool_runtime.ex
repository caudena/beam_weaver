defmodule BeamWeaver.Core.ToolRuntime do
  @moduledoc """
  Runtime data available to tools during execution.

  A tool receives it by declaring an injected argument with the `:tool_runtime`
  source, such as `injected :runtime, :tool_runtime`. It bundles the tool call,
  the state that the `:state` source gives (in an agent, without its private
  keys), the graph runtime, and the run's context, store, config and
  checkpointer.
  """

  alias BeamWeaver.Stream.Events

  defstruct [
    :tool,
    :tool_name,
    :tool_call,
    :tool_call_id,
    :args,
    :state,
    :runtime,
    :context,
    :store,
    :checkpointer,
    :config,
    :execution_info,
    :server_info,
    tools: []
  ]

  @type t :: %__MODULE__{
          tool: term(),
          tool_name: String.t() | nil,
          tool_call: map(),
          tool_call_id: String.t() | nil,
          args: map(),
          state: term(),
          runtime: BeamWeaver.Graph.Runtime.t() | nil,
          context: term(),
          store: term(),
          checkpointer: term(),
          config: term(),
          execution_info: term(),
          server_info: term(),
          tools: [term()]
        }

  @spec new(keyword()) :: t()
  def new(opts) do
    runtime = Keyword.get(opts, :runtime)

    %__MODULE__{
      tool: Keyword.get(opts, :tool),
      tool_name: Keyword.get(opts, :tool_name),
      tool_call: Keyword.get(opts, :tool_call, %{}),
      tool_call_id: Keyword.get(opts, :tool_call_id),
      args: Keyword.get(opts, :args, %{}),
      state: Keyword.get(opts, :state),
      runtime: runtime,
      context: runtime_value(runtime, :context),
      store: runtime_value(runtime, :store),
      checkpointer: runtime_value(runtime, :checkpointer),
      config: runtime_value(runtime, :config),
      execution_info: runtime_value(runtime, :execution),
      server_info: runtime_value(runtime, :server_info),
      tools: Keyword.get(opts, :tools, [])
    }
  end

  @doc """
  Emits a streamed output delta for the current tool call.

  The event is visible through typed event streams as `%BeamWeaver.Stream.Events.ToolDelta{}`.
  When no stream writer is installed, for example outside a graph/tool runtime,
  this is a no-op.
  """
  @spec emit_output_delta(t(), term()) :: :ok
  def emit_output_delta(%__MODULE__{runtime: %{stream_writer: writer}} = tool_runtime, delta)
      when is_function(writer, 1) do
    writer.(%Events.ToolDelta{tool_call_id: tool_runtime.tool_call_id, delta: delta})

    :ok
  end

  def emit_output_delta(%__MODULE__{}, _delta), do: :ok

  defp runtime_value(nil, _field), do: nil
  defp runtime_value(runtime, field) when is_map(runtime), do: Map.get(runtime, field)
end
