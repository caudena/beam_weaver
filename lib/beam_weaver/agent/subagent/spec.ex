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
    response_format: nil,
    capture_output: nil,
    execution_mode: :agent_loop,
    base_middleware: [],
    filesystem: nil,
    todo_list: nil,
    inherit_messages: false
  ]

  def new(opts \\ []) do
    opts =
      opts
      |> Map.new()
      |> normalize_keys()

    struct(__MODULE__, opts)
  end

  def from_agent_module(module, opts \\ []) when is_atom(module) do
    Code.ensure_compiled!(module)

    unless function_exported?(module, :__beam_weaver_agent_spec__, 0) do
      raise ArgumentError, "#{inspect(module)} is not a BeamWeaver agent module"
    end

    agent = module.__beam_weaver_agent_spec__()
    opts = opts |> Map.new() |> normalize_keys()

    base =
      %{
        name: agent.name,
        description: agent.description,
        system_prompt: agent.system_prompt,
        model: agent.model,
        tools: agent.tools,
        middleware: agent.middleware,
        interrupt_on: agent.interrupt_on,
        skills: agent.skills,
        response_format: agent.response_format,
        execution_mode: agent.execution_mode
      }
      |> Map.reject(fn {_key, value} -> value in [nil, []] end)

    base
    |> Map.merge(opts)
    |> new()
  end

  defp normalize_keys(map) do
    Map.new(map, fn
      {key, _value} when is_binary(key) ->
        raise ArgumentError, "subagent spec options must use atom keys, got #{inspect(key)}"

      pair ->
        pair
    end)
  end
end
