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

defmodule BeamWeaver.Stream.Events.Token do
  @moduledoc false
  defstruct [:text, metadata: %{}]
end

defmodule BeamWeaver.Stream.Events.MessageChunk do
  @moduledoc false
  defstruct [:chunk, metadata: %{}]
end

defmodule BeamWeaver.Stream.Events.Message do
  @moduledoc false
  defstruct [:message, metadata: %{}]
end

defmodule BeamWeaver.Stream.Events.ToolCallChunk do
  @moduledoc false
  defstruct [:chunk, metadata: %{}]
end

defmodule BeamWeaver.Stream.Events.ToolStart do
  @moduledoc false
  defstruct [:tool_call_id, :tool_name, input: %{}, metadata: %{}]
end

defmodule BeamWeaver.Stream.Events.ToolDelta do
  @moduledoc false
  defstruct [:tool_call_id, :delta, metadata: %{}]
end

defmodule BeamWeaver.Stream.Events.ToolFinish do
  @moduledoc false
  defstruct [:tool_call_id, :output, metadata: %{}]
end

defmodule BeamWeaver.Stream.Events.ToolError do
  @moduledoc false
  defstruct [:tool_call_id, :message, :error_type, metadata: %{}]
end

defmodule BeamWeaver.Stream.Events.GraphUpdate do
  @moduledoc false
  defstruct [:update, metadata: %{}]
end

defmodule BeamWeaver.Stream.Events.GraphValue do
  @moduledoc false
  defstruct [:value, metadata: %{}]
end

defmodule BeamWeaver.Stream.Events.Checkpoint do
  @moduledoc false
  defstruct [:config, :values, :step, metadata: %{}]
end

defmodule BeamWeaver.Stream.Events.Task do
  @moduledoc false
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
  @moduledoc false
  defstruct [:status, :namespace, :graph_name, :trigger_call_id, :error, metadata: %{}]
end

defmodule BeamWeaver.Stream.Events.Debug do
  @moduledoc false
  defstruct [:payload, metadata: %{}]
end

defmodule BeamWeaver.Stream.Events.Custom do
  @moduledoc false
  defstruct [:payload, metadata: %{}]
end

defmodule BeamWeaver.Stream.Events.Error do
  @moduledoc false
  defstruct [:error, metadata: %{}]
end

defmodule BeamWeaver.Stream.Events.Done do
  @moduledoc false
  defstruct [:result, :usage, metadata: %{}]
end
