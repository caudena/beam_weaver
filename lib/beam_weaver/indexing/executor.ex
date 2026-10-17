defmodule BeamWeaver.Indexing.Executor do
  @moduledoc false

  alias BeamWeaver.Indexing.Record
  alias BeamWeaver.Indexing.RecordManager
  alias BeamWeaver.Indexing.Result
  alias BeamWeaver.VectorStore

  @spec apply_plan(term(), term() | nil, map(), term(), keyword()) :: {:ok, Result.t()}
  def apply_plan(vector_store, record_manager, planned, namespace, opts) do
    to_index = Enum.filter(planned.documents, &(&1.action in [:add, :update]))
    skipped = Enum.count(planned.documents, &(&1.action == :skip))
    batch_size = Keyword.get(opts, :batch_size, length(to_index))

    result =
      to_index
      |> Enum.chunk_every(max(batch_size, 1))
      |> Enum.reduce(%Result{skipped: skipped}, fn batch, acc ->
        docs = Enum.map(batch, & &1.document)

        with {:ok, ids} <- VectorStore.add_documents(vector_store, docs, opts),
             :ok <- put_records(record_manager, batch, namespace, opts) do
          %{
            acc
            | added: acc.added + Enum.count(batch, &(&1.action == :add)),
              updated: acc.updated + Enum.count(batch, &(&1.action == :update)),
              indexed_ids: acc.indexed_ids ++ ids
          }
        else
          {:error, error} ->
            %{
              acc
              | failed: acc.failed + length(batch),
                failed_ids: acc.failed_ids ++ Enum.map(docs, & &1.id),
                errors: [error | acc.errors]
            }
        end
      end)

    {:ok, result}
  end

  defp put_records(nil, _batch, _namespace, _opts), do: :ok

  defp put_records(record_manager, batch, namespace, opts) do
    Enum.reduce_while(batch, :ok, fn item, :ok ->
      record = %Record{
        id: item.document.id,
        source_id: item.source_id,
        hash: item.hash,
        namespace: namespace,
        metadata: Keyword.get(opts, :record_metadata, %{})
      }

      case RecordManager.put(record_manager, record, namespace: namespace) do
        :ok -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end
end
