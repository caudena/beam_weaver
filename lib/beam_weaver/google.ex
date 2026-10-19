defmodule BeamWeaver.Google do
  @moduledoc ~S"""
  Gemini Developer API chat, media, hosted tool declarations and token counting.

  Constructors return configured values; invocation makes the provider request.
  Load credentials into `config :beam_weaver, :google` in your application's
  runtime configuration. Explicit connection options override configured defaults.
  See the [Google guide](providers/google.md) for an executed request, endpoint
  choices, supported options and account/resource requirements.

  Native tool helpers construct declarations. Hosted tools execute at the provider;
  client actions require an application executor. Keep full returned messages
  for continuation and inspect outcomes rather than HTTP success alone.
  """

  alias BeamWeaver.Google.ChatModel

  @doc "Builds a Google Gemini chat model."
  @spec chat_model(keyword() | map()) :: ChatModel.t()
  def chat_model(opts \\ []), do: ChatModel.new(opts)

  @doc "Returns provider tool helpers."
  def tools, do: BeamWeaver.Google.Tools
end
