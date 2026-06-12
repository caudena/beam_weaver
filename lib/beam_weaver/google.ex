defmodule BeamWeaver.Google do
  @moduledoc """
  Google Gemini Developer API provider namespace.
  """

  alias BeamWeaver.Google.ChatModel

  @doc "Builds a Google Gemini chat model."
  @spec chat_model(keyword() | map()) :: ChatModel.t()
  def chat_model(opts \\ []), do: ChatModel.new(opts)

  @doc "Returns provider tool helpers."
  def tools, do: BeamWeaver.Google.Tools
end
