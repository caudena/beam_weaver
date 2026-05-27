defmodule BeamWeaver.Agent.ToolCallRequest do
  @moduledoc """
  Immutable tool-call request passed through agent middleware.
  """

  @fields [:tool_call, :tool, :tool_set, :state, :runtime]

  defstruct [:tool_call, :tool, :tool_set, :state, :runtime]

  @type t :: %__MODULE__{
          tool_call: map(),
          tool: term(),
          tool_set: BeamWeaver.Agent.ToolSet.t() | nil,
          state: term(),
          runtime: BeamWeaver.Graph.Runtime.t() | nil
        }

  @spec override(t(), keyword() | map()) :: t()
  def override(%__MODULE__{} = request, overrides) when is_list(overrides),
    do: override(request, Map.new(overrides))

  def override(%__MODULE__{} = request, overrides) when is_map(overrides) do
    Enum.reduce(overrides, request, fn {key, value}, acc ->
      key = normalize_field(key)

      if key in @fields do
        Map.put(acc, key, value)
      else
        acc
      end
    end)
  end

  defp normalize_field(key) when is_atom(key), do: key
  defp normalize_field("tool_call"), do: :tool_call
  defp normalize_field("tool"), do: :tool
  defp normalize_field("tool_set"), do: :tool_set
  defp normalize_field("state"), do: :state
  defp normalize_field("runtime"), do: :runtime
  defp normalize_field(key), do: key
end
