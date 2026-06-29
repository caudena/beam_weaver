defmodule BeamWeaver.Anthropic.Middleware.PromptCaching do
  @moduledoc """
  Anthropic prompt-cache helper middleware.

  This lightweight adapter returns call options that place a cache breakpoint on
  the request. Agent integrations can merge these options into a model call.
  """

  defstruct cache_control: %{type: :ephemeral}

  @type t :: %__MODULE__{cache_control: map()}

  @spec new(keyword() | map()) :: t()
  def new(opts \\ []) do
    attrs = if is_map(opts), do: opts, else: Map.new(opts)
    struct(__MODULE__, attrs)
  end

  @spec call_opts(t()) :: keyword()
  def call_opts(%__MODULE__{cache_control: cache_control}), do: [cache_control: cache_control]
end
