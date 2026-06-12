defmodule BeamWeaver.Tools.Subagents do
  @moduledoc """
  Toolkit for the standard DeepAgents `task` tool.

  This is a composable convenience wrapper around
  `BeamWeaver.Agent.Middleware.Subagents`. Applications can include the
  middleware directly when they also want its prompt/state behavior; this module
  exists for places that accept normal toolkits.
  """

  @behaviour BeamWeaver.ToolKit

  alias BeamWeaver.Agent.Middleware.Subagents

  @impl true
  def tools(opts \\ []) do
    opts
    |> Subagents.new()
    |> Subagents.tools()
  end
end
