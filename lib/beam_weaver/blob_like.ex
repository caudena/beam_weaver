defprotocol BeamWeaver.BlobLike do
  @moduledoc """
  Converts common values into `BeamWeaver.Blob` without relying on reflection.
  """

  @fallback_to_any true

  @spec to_blob(t()) :: {:ok, BeamWeaver.Blob.t()} | {:error, BeamWeaver.Core.Error.t()}
  def to_blob(value)
end

defimpl BeamWeaver.BlobLike, for: BeamWeaver.Blob do
  def to_blob(blob), do: {:ok, blob}
end

defimpl BeamWeaver.BlobLike, for: BitString do
  def to_blob(value), do: BeamWeaver.Blob.from_data(value)
end

defimpl BeamWeaver.BlobLike, for: Map do
  alias BeamWeaver.Blob
  alias BeamWeaver.Core.Error

  def to_blob(value) do
    data = fetch_any(value, [:data, "data", :content, "content", :text, "text"])
    source = fetch_any(value, [:source, "source", :path, "path"])
    metadata = fetch_any(value, [:metadata, "metadata"]) || %{}
    encoding = fetch_any(value, [:encoding, "encoding"]) || "utf-8"

    cond do
      not is_map(metadata) ->
        {:error, Error.new(:invalid_blob_like, "blob metadata must be a map")}

      is_binary(data) ->
        Blob.from_data(data, source: source, metadata: metadata, encoding: encoding)

      is_binary(source) ->
        Blob.from_path(source, metadata: metadata, encoding: encoding)

      true ->
        {:error, Error.new(:invalid_blob_like, "blob-like maps must include data/content or source/path")}
    end
  end

  defp fetch_any(map, keys) do
    Enum.find_value(keys, fn key ->
      if Map.has_key?(map, key), do: Map.fetch!(map, key), else: nil
    end)
  end
end

defimpl BeamWeaver.BlobLike, for: Any do
  alias BeamWeaver.Core.Error

  def to_blob(_value),
    do: {:error, Error.new(:invalid_blob_like, "expected a blob, map, or binary")}
end
