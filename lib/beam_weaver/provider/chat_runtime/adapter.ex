defmodule BeamWeaver.Provider.ChatRuntime.Adapter do
  @moduledoc """
  Runtime adapter used by provider chat models.

  The adapter keeps provider-specific request, transport, decode, and stream
  functions explicit while allowing `BeamWeaver.Provider.ChatRuntime` to own
  the common invocation flow.
  """

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message

  @type request_fun :: (term(), [Message.t()], keyword() -> {:ok, map()} | {:error, Error.t() | term()})
  @type provider_fun :: (term(), map(), keyword() -> {:ok, term()} | {:error, Error.t() | term()})
  @type decode_fun :: (term(), keyword() -> {:ok, Message.t()} | {:error, Error.t() | term()})
  @type parse_fun :: (Message.t(), keyword() -> {:ok, Message.t()} | {:error, Error.t() | term()})
  @type metadata_fun :: (term(), map(), keyword() -> map())

  @enforce_keys [:request, :invoke, :stream, :stream_response, :decode]
  defstruct [
    :request,
    :invoke,
    :stream,
    :stream_response,
    :stream_events,
    :decode,
    :parse,
    :metadata,
    :source
  ]

  @type t :: %__MODULE__{
          request: request_fun(),
          invoke: provider_fun(),
          stream: provider_fun(),
          stream_response: provider_fun(),
          stream_events: provider_fun() | nil,
          decode: decode_fun(),
          parse: parse_fun() | nil,
          metadata: metadata_fun() | nil,
          source: atom() | nil
        }
end
