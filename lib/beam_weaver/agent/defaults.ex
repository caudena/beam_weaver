defmodule BeamWeaver.Agent.Defaults do
  @moduledoc """
  Agent capability defaults and construction helpers.

  `BeamWeaver.Agent.build/1` requires an explicit model. This module keeps
  graph construction defaults in one place without adding Python compatibility
  aliases.
  """

  alias BeamWeaver.Core.Error

  @base_agent_prompt """
  You are a DeepAgent. Use the filesystem tools for durable intermediate work,
  keep a TODO list for multi-step tasks, and delegate focused work to subagents
  when that reduces context pressure.
  """

  @doc "Returns the base system prompt used by advanced agent capabilities."
  @spec base_agent_prompt() :: String.t()
  def base_agent_prompt, do: @base_agent_prompt

  @doc """
  Returns BeamWeaver's DeepAgents default-model decision.

  Python DeepAgents has a default-model helper. BeamWeaver intentionally
  requires `:model` so deployments do not silently select a provider or spend
  credentials.
  """
  @spec get_default_model() :: {:error, Error.t()}
  def get_default_model do
    {:error, Error.new(:invalid_agent, "BeamWeaver.Agent.build/1 requires a :model option")}
  end
end
