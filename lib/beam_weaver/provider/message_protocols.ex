defprotocol BeamWeaver.Provider.EncodeMessage do
  @moduledoc """
  Encodes a message-like value for a provider boundary.
  """

  @fallback_to_any true

  def encode(value, opts)
end

defimpl BeamWeaver.Provider.EncodeMessage, for: BeamWeaver.Core.Message do
  def encode(message, opts) do
    case Keyword.get(opts, :provider) do
      :openai ->
        with {:ok, [encoded]} <- BeamWeaver.OpenAI.Messages.to_responses_input([message]) do
          {:ok, encoded}
        end

      :anthropic ->
        BeamWeaver.Anthropic.Messages.encode_message(message, opts)

      :google ->
        BeamWeaver.Google.Messages.encode_message(message, opts)

      provider
      when provider in [
             :google_vertexai,
             :bedrock,
             :bedrock_converse,
             :groq
           ] ->
        BeamWeaver.Provider.GenericMessages.encode(message, provider)

      provider ->
        {:error,
         BeamWeaver.Core.Error.new(
           :unsupported_provider,
           "message encoding provider is not supported",
           %{
             provider: provider
           }
         )}
    end
  end
end

defimpl BeamWeaver.Provider.EncodeMessage, for: Any do
  def encode(value, opts) do
    with {:ok, message} <- BeamWeaver.Core.MessageLike.to_message(value) do
      BeamWeaver.Provider.EncodeMessage.encode(message, opts)
    end
  end
end

defprotocol BeamWeaver.Provider.DecodeMessage do
  @moduledoc """
  Decodes a provider payload into a BeamWeaver message.
  """

  @fallback_to_any true

  def decode(value, opts)
end

defimpl BeamWeaver.Provider.DecodeMessage, for: Map do
  def decode(payload, opts) do
    case Keyword.get(opts, :provider) do
      :openai ->
        BeamWeaver.OpenAI.Messages.response_to_message(payload)

      :anthropic ->
        BeamWeaver.Anthropic.Messages.decode_message(payload, opts)

      :google ->
        BeamWeaver.Google.Messages.decode_message(payload, opts)

      provider
      when provider in [
             :google_vertexai,
             :bedrock,
             :bedrock_converse,
             :groq
           ] ->
        BeamWeaver.Provider.GenericMessages.decode(payload, provider)

      provider ->
        {:error,
         BeamWeaver.Core.Error.new(
           :unsupported_provider,
           "message decoding provider is not supported",
           %{
             provider: provider
           }
         )}
    end
  end
end

defimpl BeamWeaver.Provider.DecodeMessage, for: Any do
  def decode(_value, _opts) do
    {:error, BeamWeaver.Core.Error.new(:invalid_message, "provider payload must be a map")}
  end
end
