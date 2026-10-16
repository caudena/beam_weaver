defmodule BeamWeaver.Graph.Execution.Step do
  @moduledoc false

  @reserved_channels [
    "__error__",
    "__error_source_node__",
    "__interrupt__",
    "__no_writes__",
    "__push__",
    "__resume__",
    "__return__",
    "__route__"
  ]

  @type task_write :: %{task_id: String.t(), channel: String.t(), value: term(), path: String.t()}

  @spec reserved_channel?(term()) :: boolean()
  def reserved_channel?(channel), do: to_string(channel) in @reserved_channels
end
