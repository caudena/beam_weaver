defmodule BeamWeaver.Agent.ModelResponse do
  @moduledoc """
  Normalized result from an agent model call.
  """

  defstruct messages: [], structured_response: nil, tool_set: nil, usage: nil, commands: []

  @type t :: %__MODULE__{
          messages: [BeamWeaver.Core.Message.t()],
          structured_response: term(),
          tool_set: BeamWeaver.Agent.ToolSet.t() | nil,
          usage: BeamWeaver.Agent.Usage.t() | nil,
          commands: [BeamWeaver.Graph.Command.t()]
        }
end
