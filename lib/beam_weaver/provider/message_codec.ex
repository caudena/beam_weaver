defmodule BeamWeaver.Provider.MessageCodec do
  @moduledoc """
  Converts single messages to and from a provider's wire format.

      MessageCodec.encode(Message.user("hi"), provider: :anthropic)
      MessageCodec.decode(response_body, provider: :openai)

  Supported providers: `:openai`, `:anthropic`, and `:google`.
  """

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message

  @doc """
  Encodes a message (or anything `Message.from/1` accepts) for `opts[:provider]`.

  Returns one map, except for `:openai`, whose Responses API input has a
  separate item for each tool call: an assistant message with tool calls
  encodes to a list of its message item and one `function_call` item per call.
  """
  @spec encode(term(), keyword()) :: {:ok, map() | [map()]} | {:error, Error.t()}
  def encode(value, opts) do
    with {:ok, message} <- Message.from(value) do
      case Keyword.get(opts, :provider) do
        :openai ->
          case BeamWeaver.OpenAI.Messages.to_responses_input([message]) do
            {:ok, [item]} -> {:ok, item}
            result -> result
          end

        :anthropic ->
          BeamWeaver.Anthropic.Messages.encode_message(message, opts)

        :google ->
          BeamWeaver.Google.Messages.encode_message(message, opts)

        provider ->
          {:error,
           Error.new(:unsupported_provider, "message encoding provider is not supported", %{provider: provider})}
      end
    end
  end

  @doc "Decodes a provider payload map from `opts[:provider]` into a message."
  @spec decode(term(), keyword()) :: {:ok, Message.t()} | {:error, Error.t()}
  def decode(payload, opts) when is_map(payload) and not is_struct(payload) do
    case Keyword.get(opts, :provider) do
      :openai ->
        BeamWeaver.OpenAI.Messages.response_to_message(payload)

      :anthropic ->
        BeamWeaver.Anthropic.Messages.decode_message(payload, opts)

      :google ->
        BeamWeaver.Google.Messages.decode_message(payload, opts)

      provider ->
        {:error, Error.new(:unsupported_provider, "message decoding provider is not supported", %{provider: provider})}
    end
  end

  def decode(_value, _opts), do: {:error, Error.new(:invalid_message, "provider payload must be a map")}
end
