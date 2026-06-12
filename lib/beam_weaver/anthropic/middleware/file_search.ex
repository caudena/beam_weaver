defmodule BeamWeaver.Anthropic.Middleware.FileSearch do
  @moduledoc """
  Convenience helper for Anthropic file-search style tool-search declarations.
  """

  alias BeamWeaver.Anthropic.Tools

  defstruct opts: []

  @spec new(keyword()) :: %__MODULE__{}
  def new(opts \\ []), do: %__MODULE__{opts: opts}

  @spec call_opts(%__MODULE__{}) :: keyword()
  def call_opts(%__MODULE__{opts: opts}), do: [tools: [Tools.tool_search(opts)]]
end
