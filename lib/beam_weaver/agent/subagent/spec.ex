defmodule BeamWeaver.Agent.Subagent.Spec do
  @moduledoc "Declarative synchronous DeepAgents subagent spec."

  defstruct [
    :name,
    :description,
    :system_prompt,
    :model,
    tools: nil,
    middleware: [],
    interrupt_on: nil,
    skills: nil,
    permissions: nil,
    response_format: nil
  ]

  def new(opts \\ []) do
    opts =
      opts
      |> Map.new()
      |> normalize_keys()

    struct(__MODULE__, opts)
  end

  defp normalize_keys(map) do
    Map.new(map, fn
      {"name", value} -> {:name, value}
      {"description", value} -> {:description, value}
      {"system_prompt", value} -> {:system_prompt, value}
      {"model", value} -> {:model, value}
      {"tools", value} -> {:tools, value}
      {"middleware", value} -> {:middleware, value}
      {"interrupt_on", value} -> {:interrupt_on, value}
      {"skills", value} -> {:skills, value}
      {"permissions", value} -> {:permissions, value}
      {"response_format", value} -> {:response_format, value}
      pair -> pair
    end)
  end
end
