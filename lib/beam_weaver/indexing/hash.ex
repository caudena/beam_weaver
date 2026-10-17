defmodule BeamWeaver.Indexing.Hash do
  @moduledoc false

  alias BeamWeaver.Core.Document
  alias BeamWeaver.Core.Error

  import Bitwise

  @spec document_hash(Document.t()) :: String.t()
  def document_hash(%Document{} = doc) do
    :sha256
    |> :crypto.hash(:erlang.term_to_binary({doc.content, doc.metadata}))
    |> Base.encode16(case: :lower)
  end

  @spec with_hashed_id(Document.t(), keyword()) :: {:ok, Document.t()} | {:error, Error.t()}
  def with_hashed_id(%Document{} = document, opts) do
    encoder = Keyword.get(opts, :key_encoder, :sha256)

    with {:ok, id} <- document_hash_id(document, encoder) do
      {:ok, %{document | id: id}}
    end
  rescue
    exception ->
      {:error, Error.new(:document_hash_error, Exception.message(exception))}
  end

  @spec hash_string(String.t(), atom() | String.t()) :: {:ok, String.t()} | {:error, Error.t()}
  def hash_string(text, algorithm) when is_binary(text) do
    case normalize_hash_algorithm(algorithm) do
      {:ok, :sha1} -> {:ok, uuid5(digest(:sha, text))}
      {:ok, algorithm} -> {:ok, digest(algorithm, text)}
      error -> error
    end
  end

  defp document_hash_id(%Document{} = document, encoder) when is_function(encoder, 1),
    do: {:ok, encoder.(document) |> to_string()}

  defp document_hash_id(%Document{} = document, encoder) do
    with {:ok, algorithm} <- normalize_hash_algorithm(encoder),
         {:ok, content_hash} <- hash_string(document.content, algorithm),
         {:ok, metadata_json} <- canonical_json(document.metadata),
         {:ok, metadata_hash} <- hash_string(metadata_json, algorithm) do
      hash_string(content_hash <> metadata_hash, algorithm)
    end
  end

  defp normalize_hash_algorithm(algorithm) when algorithm in [:sha1, "sha1"], do: {:ok, :sha1}

  defp normalize_hash_algorithm(algorithm) when algorithm in [:sha256, "sha256"],
    do: {:ok, :sha256}

  defp normalize_hash_algorithm(algorithm) when algorithm in [:sha512, "sha512"],
    do: {:ok, :sha512}

  defp normalize_hash_algorithm(algorithm) when algorithm in [:blake2b, "blake2b"],
    do: {:ok, :blake2b}

  defp normalize_hash_algorithm(algorithm) do
    {:error,
     Error.new(:unsupported_hash_algorithm, "unsupported document hash algorithm", %{
       algorithm: algorithm
     })}
  end

  defp digest(algorithm, text) do
    algorithm
    |> :crypto.hash(text)
    |> Base.encode16(case: :lower)
  end

  defp uuid5(name) do
    namespace = <<0::112, 1984::unsigned-big-integer-size(16)>>
    <<a::32, b::16, c::16, d::16, e::48, _rest::binary>> = :crypto.hash(:sha, namespace <> name)
    c = (c &&& 0x0FFF) ||| 0x5000
    d = (d &&& 0x3FFF) ||| 0x8000

    BeamWeaver.Core.ID.format_uuid(<<a::32, b::16, c::16, d::16, e::48>>)
  end

  defp canonical_json(value) do
    {:ok, canonical_json!(value)}
  rescue
    exception ->
      {:error,
       Error.new(:document_hash_error, "failed to hash metadata", %{
         reason: Exception.message(exception)
       })}
  end

  defp canonical_json!(value) when is_map(value) do
    body =
      value
      |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
      |> Enum.map_join(", ", fn {key, nested} ->
        BeamWeaver.JSON.encode!(to_string(key)) <> ": " <> canonical_json!(nested)
      end)

    "{" <> body <> "}"
  end

  defp canonical_json!(value) when is_list(value) do
    "[" <> Enum.map_join(value, ", ", &canonical_json!/1) <> "]"
  end

  defp canonical_json!(value), do: BeamWeaver.JSON.encode!(value)
end
