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
  def plan(nil, docs, namespace, _force_update, opts) do
    docs
    |> Result.traverse(fn doc ->
      with {:ok, source_id} <- Documents.source_id(doc, opts) do
        item = %{document: doc, hash: Hash.document_hash(doc), source_id: source_id, action: :add}
        {:ok, item}
      end
    end)
    |> case do
      {:ok, planned} ->
        {:ok,
         %{
           namespace: namespace,
           documents: planned,
           current_ids: MapSet.new(Enum.map(docs, & &1.id))
         }}

      other ->
        other
    end
  end

  def plan(record_manager, docs, namespace, force_update, opts) do
    docs
    |> Result.traverse(fn doc ->
      doc_hash = Hash.document_hash(doc)

      with {:ok, source_id} <- Documents.source_id(doc, opts),
           {:ok, record} <- RecordManager.get(record_manager, doc.id, namespace: namespace) do
        item = %{document: doc, hash: doc_hash, source_id: source_id}

        action =
          case record do
            nil -> :add
            %Record{hash: ^doc_hash} when not force_update -> :skip
            %Record{} -> :update
          end

        {:ok, Map.put(item, :action, action)}
      end
    end)
    |> case do
      {:ok, planned} ->
        planned = dedupe_planned(planned)

        {:ok,
         %{
           namespace: namespace,
           documents: planned,
           current_ids: MapSet.new(Enum.map(docs, & &1.id))
         }}

      other ->
        other
    end
  end

  defp dedupe_planned(planned) do
    {_seen, deduped} =
      Enum.reduce(planned, {MapSet.new(), []}, fn item, {seen, acc} ->
        id = item.document.id

        if MapSet.member?(seen, id) do
          {seen, [%{item | action: :skip} | acc]}
        else
          {MapSet.put(seen, id), [item | acc]}
        end
      end)

    Enum.reverse(deduped)
  end
end
