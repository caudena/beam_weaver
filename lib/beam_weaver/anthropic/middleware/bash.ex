defmodule BeamWeaver.Anthropic.Middleware.Bash do
  @moduledoc """
  Convenience helper for Anthropic's bash server tool.
  """

  alias BeamWeaver.Anthropic.Tools

  defstruct opts: []

  @spec new(keyword()) :: %__MODULE__{}
  def new(opts \\ []), do: %__MODULE__{opts: opts}

  @spec call_opts(%__MODULE__{}) :: keyword()
  def call_opts(%__MODULE__{opts: opts}), do: [tools: [Tools.bash(opts)]]
end
