defmodule BeamWeaver.Serialization.Encrypted do
  @moduledoc """
  AES-256-GCM wrapper for BeamWeaver serialization codecs.

  This codec keeps the default safe JSON wire format as the plaintext payload
  and encrypts it only when callers opt in with an explicit 32-byte key. It is a
  checkpoint/store adapter concern, not a global serialization side effect.
  """

  @behaviour BeamWeaver.Serialization.Codec

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Serialization.JSON

  @aad "beam_weaver.serialization.v1"
  @cipher :aes_256_gcm
  @version 1

  @impl true
  def dump(value, opts \\ []) do
    inner_codec = option(opts, :inner_codec, JSON)

    with {:ok, key} <- encryption_key(opts),
         {:ok, plaintext} <- inner_codec.dump(value, opts) do
      nonce = :crypto.strong_rand_bytes(12)
      {ciphertext, tag} = :crypto.crypto_one_time_aead(@cipher, key, nonce, plaintext, @aad, true)

      envelope = %{
        "version" => @version,
        "alg" => "A256GCM",
        "nonce" => Base.encode64(nonce),
        "tag" => Base.encode64(tag),
        "ciphertext" => Base.encode64(ciphertext)
      }

      {:ok, BeamWeaver.JSON.encode!(envelope)}
    end
  end

  @impl true
  def load(binary, opts \\ []) when is_binary(binary) do
    inner_codec = option(opts, :inner_codec, JSON)

    with {:ok, key} <- encryption_key(opts),
         {:ok, envelope} <- BeamWeaver.JSON.decode(binary) do
      if encrypted_envelope?(envelope) do
        with :ok <- validate_envelope(envelope),
             {:ok, nonce} <- decode64(envelope["nonce"], "nonce"),
             {:ok, tag} <- decode64(envelope["tag"], "tag"),
             {:ok, ciphertext} <- decode64(envelope["ciphertext"], "ciphertext"),
             {:ok, plaintext} <- decrypt(key, nonce, ciphertext, tag) do
          inner_codec.load(plaintext, opts)
        end
      else
        {:error,
         Error.new(:serialization_error, "encrypted payload envelope is required", %{
           reason: :missing_envelope
         })}
      end
    else
      {:error, %Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error,
         Error.new(:serialization_error, "encrypted serialization failed", %{
           reason: inspect(reason)
         })}
    end
  end

  defp encryption_key(opts) do
    cond do
      key = option(opts, :encryption_key) ->
        validate_key(key)

      key = option(opts, :encryption_key_base64) ->
        case Base.decode64(key) do
          {:ok, decoded} -> validate_key(decoded)
          :error -> invalid_key("base64 encryption key is invalid")
        end

      true ->
        invalid_key("encrypted serialization requires :encryption_key or :encryption_key_base64")
    end
  end

  defp validate_key(key) when is_binary(key) and byte_size(key) == 32, do: {:ok, key}

  defp validate_key(_key) do
    invalid_key("AES-256-GCM encryption key must be exactly 32 bytes")
  end

  defp invalid_key(message), do: {:error, Error.new(:invalid_serialization_key, message)}

  defp validate_envelope(%{
         "version" => @version,
         "alg" => "A256GCM",
         "nonce" => nonce,
         "tag" => tag,
         "ciphertext" => ciphertext
       })
       when is_binary(nonce) and is_binary(tag) and is_binary(ciphertext),
       do: :ok

  defp validate_envelope(_envelope) do
    {:error, Error.new(:serialization_error, "encrypted payload envelope is invalid")}
  end

  defp encrypted_envelope?(%{} = envelope) do
    Enum.any?(["version", "alg", "nonce", "tag", "ciphertext"], &Map.has_key?(envelope, &1))
  end

  defp encrypted_envelope?(_value), do: false

  defp decode64(value, field) do
    case Base.decode64(value) do
      {:ok, decoded} ->
        {:ok, decoded}

      :error ->
        {:error, Error.new(:serialization_error, "encrypted #{field} is not valid base64")}
    end
  end

  defp decrypt(key, nonce, ciphertext, tag) do
    case :crypto.crypto_one_time_aead(@cipher, key, nonce, ciphertext, @aad, tag, false) do
      plaintext when is_binary(plaintext) ->
        {:ok, plaintext}

      :error ->
        {:error, Error.new(:serialization_error, "encrypted payload authentication failed")}
    end
  end

  defp option(opts, key, default \\ nil) do
    opts_value = Keyword.get(opts, key, :missing)
    serialization = Keyword.get(opts, :serialization, [])

    serialization_value =
      if is_list(serialization) do
        Keyword.get(serialization, key, :missing)
      else
        :missing
      end

    cond do
      opts_value != :missing -> opts_value
      serialization_value != :missing -> serialization_value
      true -> default
    end
  end
end
