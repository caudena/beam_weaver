defmodule BeamWeaver.Agent.ToolCallRequest do
  @moduledoc """
  Immutable tool-call request passed through agent middleware.
  """

  defstruct [:tool_call, :tool, :tool_set, :state, :runtime]

  @type t :: %__MODULE__{
          tool_call: map(),
          tool: term(),
          tool_set: term(),
          state: term(),
          runtime: BeamWeaver.Graph.Runtime.t() | nil
        }

  @doc "Returns a copy of the request with the given fields replaced."
  @spec override(t(), keyword()) :: t()
  def override(%__MODULE__{} = request, overrides) when is_list(overrides),
    do: struct!(request, overrides)
end
