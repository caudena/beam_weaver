defmodule BeamWeaver.Agent.Subagent.Helpers do
  @moduledoc false

  alias BeamWeaver.Agent.Middleware.Helpers
  alias BeamWeaver.Agent.ModelRequest

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

  def agent_names(subagents), do: Enum.map_join(subagents, ", ", &"`#{&1.name}`")

  # A subagents middleware adds its `system_prompt:` text, followed by its
  # subagents under `heading`, to the system prompt; without the text, nothing.
  def with_agents_prompt(%ModelRequest{} = request, %{system_prompt: prompt}, _heading) when prompt in [nil, ""],
    do: request

  def with_agents_prompt(%ModelRequest{} = request, %{system_prompt: prompt, subagents: subagents}, heading) do
    prompt = prompt <> "\n\n" <> heading <> ":\n\n" <> available_agents(subagents)
    ModelRequest.override(request, system_message: Helpers.append_prompt(request.system_message, prompt))
  end

  def value(map, key, default \\ nil), do: BeamWeaver.MapAccess.get(map, key, default)
end
