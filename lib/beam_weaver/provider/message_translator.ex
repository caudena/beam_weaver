defmodule BeamWeaver.Provider.MessageTranslator do
  @moduledoc false

  alias BeamWeaver.Core.Message

  @callback encode_message(Message.t(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback decode_message(map(), keyword()) :: {:ok, Message.t()} | {:error, term()}
  @callback encode_messages([Message.t()], keyword()) :: {:ok, term()} | {:error, term()}
  @callback decode_stream(term(), keyword()) :: {:ok, Enumerable.t()} | {:error, term()}

  @optional_callbacks encode_messages: 2, decode_stream: 2
end
