defmodule BeamWeaver.Indexing.Documents do
  @moduledoc false

  alias BeamWeaver.Core.Document
  alias BeamWeaver.Core.Error

  alias BeamWeaver.Indexing.Hash
  alias BeamWeaver.MapAccess
  alias BeamWeaver.Result

  @spec normalize(Enumerable.t(), keyword()) :: {:ok, [Document.t()]} | {:error, Error.t()}
  def normalize(documents, opts) do
    documents
    |> Result.traverse(fn value ->
      case Document.from(value) do
        {:ok, %Document{} = document} ->
          id = document.id || document_id(document, opts)
          {:ok, %{document | id: id}}

        {:error, error} ->
          {:error, error}
      end
    end)
  end

  @spec source_id(Document.t(), keyword()) :: {:ok, String.t()} | {:error, Error.t()}
  def source_id(%Document{} = doc, opts) do
    case Keyword.get(opts, :source_id) do
      fun when is_function(fun, 1) ->
        {:ok, fun.(doc) |> to_string()}

      nil ->
        keyed_source_id(doc, opts) || {:ok, metadata_source(doc) || doc.id || "default"}

      value ->
        {:ok, to_string(value)}
    end
  end

  defp document_id(%Document{} = doc, opts) do
    case Keyword.get(opts, :id) do
      fun when is_function(fun, 1) -> fun.(doc)
      nil -> Hash.document_hash(doc)
      value -> to_string(value)
    end
  end

  defp keyed_source_id(%Document{metadata: metadata}, opts) do
    case Keyword.fetch(opts, :source_id_key) do
      {:ok, key} ->
        case MapAccess.fetch(metadata, key) do
          {:ok, nil} ->
            {:error,
             Error.new(:missing_source_id, "document source_id_key resolved to nil", %{
               source_id_key: key
             })}

          {:ok, value} ->
            {:ok, to_string(value)}

          :error ->
            {:error,
             Error.new(:missing_source_id, "document is missing source_id_key metadata", %{
               source_id_key: key
             })}
        end

      :error ->
        nil
    end
  end

  # Without a source, the chunks of a document belong to the document they were
  # split from ("parent_id"), so a shorter version's cleanup reaches them all.
  defp metadata_source(%Document{metadata: metadata}) do
    Enum.find_value([:source_id, "source_id", :source, "source", "parent_id"], fn key ->
      case MapAccess.fetch(metadata, key) do
        {:ok, nil} -> nil
        {:ok, value} -> to_string(value)
        :error -> nil
      end
    end)
  end
end
