defmodule BeamWeaver.Stream.Envelope do
  @moduledoc """
  Metadata wrapper for typed stream events.
  """

  defstruct [
    :event,
    :run_id,
    :graph,
    :node,
    :task_id,
    :step,
    namespace: [],
    metadata: %{},
    timestamp: nil
  ]

  @type t :: %__MODULE__{
          event: term(),
          run_id: String.t() | nil,
          graph: String.t() | nil,
          node: String.t() | atom() | nil,
          task_id: String.t() | nil,
          step: non_neg_integer() | nil,
          namespace: [term()],
          metadata: map(),
          timestamp: term()
        }
end

defmodule BeamWeaver.Stream.Events do
  @moduledoc """
  Typed event structs emitted inside `%BeamWeaver.Stream.Envelope{}` values.

  Stream consumers usually alias this namespace and pattern match on the event
  stored in each envelope:

      alias BeamWeaver.Stream.Events

      case envelope.event do
        %Events.Token{text: delta} -> IO.write(delta)
        %Events.ToolFinish{output: output} -> IO.inspect(output)
        _event -> :ok
      end

  Use `BeamWeaver.Stream.event_mode/1` when you need to classify an event into
  channels such as `:messages`, `:tools`, `:updates`, or `:debug`.
  """
end

defmodule BeamWeaver.Stream.Events.Token do
  @moduledoc """
  Text delta emitted by providers that support token streaming.
  """

  defstruct [:text, metadata: %{}]
end

defmodule BeamWeaver.Stream.Events.MessageChunk do
  @moduledoc """
  Provider message chunk emitted during streaming.

  Chunks can include text, reasoning blocks, usage metadata, or streamed
  tool-call fragments depending on the provider.
  """

  defstruct [:chunk, metadata: %{}]
end

defmodule BeamWeaver.Stream.Events.Message do
  @moduledoc """
  Complete assistant or tool message emitted by a graph or agent node.
  """

  defstruct [:message, metadata: %{}]
end

defmodule BeamWeaver.Stream.Events.ToolCallChunk do
  @moduledoc """
  Incremental tool-call argument chunk emitted while a model is forming a call.
  """

  defstruct [:chunk, metadata: %{}]
end

defmodule BeamWeaver.Stream.Events.ToolStart do
  @moduledoc """
  Tool execution start event with the call ID, tool name, and input payload.
  """

  defstruct [:tool_call_id, :tool_name, input: %{}, metadata: %{}]
end

defmodule BeamWeaver.Stream.Events.ToolDelta do
  @moduledoc """
  Incremental output emitted by a tool while it is still running.
  """

  defstruct [:tool_call_id, :delta, metadata: %{}]
end

defmodule BeamWeaver.Stream.Events.ToolFinish do
  @moduledoc """
  Tool execution completion event with the final output.
  """

  defstruct [:tool_call_id, :output, metadata: %{}]
end

defmodule BeamWeaver.Stream.Events.ToolError do
  @moduledoc """
  Tool execution failure event with a user-visible message and error type.
  """

  defstruct [:tool_call_id, :message, :error_type, metadata: %{}]
end

defmodule BeamWeaver.Stream.Events.GraphUpdate do
  @moduledoc """
  Per-step graph update emitted as nodes modify graph state.
  """

  defstruct [:update, metadata: %{}]
end

defmodule BeamWeaver.Stream.Events.GraphValue do
  @moduledoc """
  Graph or agent state snapshot emitted by value projections.
  """

  defstruct [:value, metadata: %{}]
end

defmodule BeamWeaver.Stream.Events.Checkpoint do
  @moduledoc """
  Checkpoint snapshot emitted when checkpoint streaming is enabled.
  """

  defstruct [:config, :values, :step, metadata: %{}]
end

defmodule BeamWeaver.Stream.Events.Task do
  @moduledoc """
  Graph task lifecycle event for node start, finish, and related task updates.
  """

  defstruct [:kind, :node, :payload, :step, :task_id, :path, metadata: %{}]

  @type t :: %__MODULE__{
          kind: atom() | String.t() | nil,
          node: atom() | String.t() | nil,
          payload: term(),
          step: non_neg_integer() | nil,
          task_id: String.t() | nil,
          path: [term()] | nil,
          metadata: map()
        }
end

defmodule BeamWeaver.Stream.Events.Lifecycle do
  @moduledoc """
  Projected lifecycle event for subgraphs and nested agent activity.
  """

  defstruct [:status, :namespace, :graph_name, :trigger_call_id, :error, metadata: %{}]
end

defmodule BeamWeaver.Stream.Events.Debug do
  @moduledoc """
  Runtime debug event for heartbeats, backpressure, interrupts, or diagnostics.
  """

  defstruct [:payload, metadata: %{}]
end

defmodule BeamWeaver.Stream.Events.Custom do
  @moduledoc """
  Application-defined event emitted through the runtime stream writer.
  """

  defstruct [:payload, metadata: %{}]
end

defmodule BeamWeaver.Stream.Events.Error do
  @moduledoc """
  Stream-level error event emitted when a live stream fails before completion.
  """

  defstruct [:error, metadata: %{}]
end

defmodule BeamWeaver.Stream.Events.Done do
  @moduledoc """
  Terminal event carrying final result or usage metadata when available.
  """

  defstruct [:result, :usage, metadata: %{}]
end
