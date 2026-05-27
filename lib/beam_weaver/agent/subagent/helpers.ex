defmodule BeamWeaver.Agent.Subagent.Helpers do
  @moduledoc false

  def available_agents([]), do: "- none"

  def available_agents(subagents) do
    Enum.map_join(subagents, "\n", fn subagent -> "- #{subagent.name}: #{subagent.description}" end)
  end

  def append_prompt(messages, prompt),
    do: BeamWeaver.Agent.Middleware.Helpers.append_prompt(messages, prompt)

  def value(map, key, default \\ nil), do: BeamWeaver.MapAccess.get(map, key, default)
end
