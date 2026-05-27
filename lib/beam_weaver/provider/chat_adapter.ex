defmodule BeamWeaver.Provider.ChatAdapter do
  @moduledoc """
  Behaviour for provider-native chat request/response adapters.

  Existing provider model structs may continue to implement
  `BeamWeaver.Core.ChatModel` directly. This behaviour is the adapter contract
  for new providers and for future refactors that move concrete clients behind
  the shared runtime.
  """

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Provider.Response

  @callback request_body(term(), [Message.t()], keyword()) :: {:ok, map()} | {:error, Error.t()}
  @callback response_to_message(map(), keyword()) :: {:ok, Message.t()} | {:error, Error.t()}
  @callback response_to_envelope(map(), term(), keyword()) ::
              {:ok, Response.t()} | {:error, Error.t()}
  @callback stream_events(term(), [Message.t()], keyword()) ::
              {:ok, Enumerable.t()} | {:error, Error.t()}
  @callback count_tokens(term(), term(), keyword()) ::
              {:ok, non_neg_integer()} | {:error, Error.t()}
  @callback validate_features(term(), keyword()) :: :ok | {:error, Error.t()}

  @optional_callbacks response_to_envelope: 3,
                      stream_events: 3,
                      count_tokens: 3,
                      validate_features: 2
end
