defmodule BeamWeaver.Anthropic.Middleware.AnthropicTools do
  @moduledoc """
  Helper for binding Anthropic-native tool declarations to model calls.
  """

  alias BeamWeaver.Anthropic.Tools

  defstruct tools: [], opts: []

  @type t :: %__MODULE__{tools: [map()], opts: keyword()}

  @spec new([term()], keyword()) :: t()
  def new(tools, opts \\ []) when is_list(tools) do
    %__MODULE__{tools: Tools.to_anthropic_tools(tools, opts), opts: opts}
  end

  @spec call_opts(t()) :: keyword()
  def call_opts(%__MODULE__{tools: tools, opts: opts}) do
    Keyword.update(opts, :tools, tools, &(tools ++ List.wrap(&1)))
  end
end
