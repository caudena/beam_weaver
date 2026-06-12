defprotocol BeamWeaver.DocumentLike do
  @moduledoc """
  Converts common document-like values into `BeamWeaver.Core.Document`.
  """

  @spec to_document(t()) ::
          {:ok, BeamWeaver.Core.Document.t()} | {:error, BeamWeaver.Core.Error.t()}
  def to_document(value)
end

defimpl BeamWeaver.DocumentLike, for: BeamWeaver.Core.Document do
  def to_document(document), do: BeamWeaver.Core.Document.validate(document) |> result(document)

  defp result(:ok, document), do: {:ok, document}
  defp result({:error, error}, _document), do: {:error, error}
end

defimpl BeamWeaver.DocumentLike, for: BitString do
  def to_document(value), do: BeamWeaver.Core.Document.new(value)
end

defimpl BeamWeaver.DocumentLike, for: Map do
  alias BeamWeaver.Core.Document
  alias BeamWeaver.Core.Error

  def to_document(value) do
    content =
      fetch_any(value, [:content, "content", :page_content, "page_content", :text, "text"])

    metadata = fetch_any(value, [:metadata, "metadata"]) || %{}
    id = fetch_any(value, [:id, "id"])

    cond do
      not is_binary(content) ->
        {:error, Error.new(:invalid_document_like, "document-like maps must include string content")}

      not is_map(metadata) ->
        {:error, Error.new(:invalid_document_like, "document metadata must be a map")}

      true ->
        Document.new(content, id: id, metadata: metadata)
    end
  end

  defp fetch_any(map, keys) do
    Enum.find_value(keys, fn key ->
      if Map.has_key?(map, key), do: Map.fetch!(map, key), else: nil
    end)
  end
end

defimpl BeamWeaver.DocumentLike, for: Any do
  alias BeamWeaver.Core.Error

  def to_document(_value),
    do: {:error, Error.new(:invalid_document_like, "expected a document, map, or string")}
end
