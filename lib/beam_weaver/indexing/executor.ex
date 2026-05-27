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

    result = %Result{skipped: skipped}

    if to_index == [] do
      {:ok, result}
    else
      batch_size = Keyword.get(opts, :batch_size, length(to_index))

      to_index
      |> Enum.chunk_every(max(batch_size, 1))
      |> Enum.reduce_while({:ok, result}, fn batch, {:ok, acc} ->
        docs = Enum.map(batch, & &1.document)

        case VectorStore.add_documents(vector_store, docs, opts) do
          {:ok, ids} ->
            case put_records(record_manager, batch, namespace, opts) do
              :ok ->
                {:cont,
                 {:ok,
                  %{
                    acc
                    | added: acc.added + Enum.count(batch, &(&1.action == :add)),
                      updated: acc.updated + Enum.count(batch, &(&1.action == :update)),
                      indexed_ids: acc.indexed_ids ++ ids
                  }}}

              {:error, error} ->
                {:cont, {:ok, %{acc | failed: acc.failed + length(batch), errors: [error | acc.errors]}}}
            end

          {:error, error} ->
            error_result = %{
              acc
              | failed: acc.failed + length(batch),
                errors: [error | acc.errors]
            }

            {:cont, {:ok, error_result}}
        end
      end)
    end
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
