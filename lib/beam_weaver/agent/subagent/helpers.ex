defmodule BeamWeaver.Agent.Subagent.Helpers do
  @moduledoc false

  def available_agents([]), do: "- none"

  def available_agents(subagents) do
    Enum.map_join(subagents, "\n", fn subagent ->
      "- #{subagent.name}: #{subagent.description}#{conversation_note(subagent)}"
    end)
  end

  # The `task` description says each call starts from the description alone,
  # so a subagent that starts from the parent's conversation says it doesn't.
  defp conversation_note(%{inherit_messages: true}),
    do:
      " (sees your conversation so far, without tool calls and their results: no need to repeat it in the description)"

  defp conversation_note(_subagent), do: ""

  def value(map, key, default \\ nil), do: BeamWeaver.MapAccess.get(map, key, default)
end
