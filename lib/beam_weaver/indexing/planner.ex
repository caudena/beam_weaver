defmodule BeamWeaver.Indexing.Planner do
  @moduledoc false

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Indexing.Documents
  alias BeamWeaver.Indexing.Hash
  alias BeamWeaver.Indexing.Record
  alias BeamWeaver.Indexing.RecordManager
  alias BeamWeaver.Result

  @spec plan(term() | nil, [BeamWeaver.Core.Document.t()], term(), boolean(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def plan(record_manager, docs, namespace, force_update, opts) do
    with {:ok, planned} <- Result.traverse(docs, &plan_document(record_manager, &1, namespace, force_update, opts)) do
      {:ok, %{namespace: namespace, documents: dedupe_planned(planned), current_ids: MapSet.new(docs, & &1.id)}}
    end
  end

  defp plan_document(record_manager, doc, namespace, force_update, opts) do
    doc_hash = Hash.document_hash(doc)

    with {:ok, source_id} <- Documents.source_id(doc, opts),
         {:ok, record} <- stored_record(record_manager, doc.id, namespace) do
      action =
        case record do
          nil -> :add
          %Record{hash: ^doc_hash} when not force_update -> :skip
          %Record{} -> :update
        end

      {:ok, %{document: doc, hash: doc_hash, source_id: source_id, action: action}}
    end
  end

  defp stored_record(nil, _id, _namespace), do: {:ok, nil}
  defp stored_record(record_manager, id, namespace), do: RecordManager.get(record_manager, id, namespace: namespace)

  defp dedupe_planned(planned) do
    {deduped, _seen} =
      Enum.map_reduce(planned, MapSet.new(), fn item, seen ->
        if MapSet.member?(seen, item.document.id),
          do: {%{item | action: :skip}, seen},
          else: {item, MapSet.put(seen, item.document.id)}
      end)

    deduped
  end
end
