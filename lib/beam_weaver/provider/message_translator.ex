defmodule BeamWeaver.Provider.MessageTranslator do
  @moduledoc """
  Behaviour for provider-specific message translation.

  Provider implementations convert between BeamWeaver's neutral message/content
  structs and each provider's wire shape at the boundary.
  """

  alias BeamWeaver.Core.Message

  @callback encode_message(Message.t(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback decode_message(map(), keyword()) :: {:ok, Message.t()} | {:error, term()}
  @callback encode_messages([Message.t()], keyword()) :: {:ok, term()} | {:error, term()}
  @callback decode_stream(term(), keyword()) :: {:ok, Enumerable.t()} | {:error, term()}

  @optional_callbacks encode_messages: 2, decode_stream: 2
end
