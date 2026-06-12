defmodule BeamWeaver.Indexing.Cleanup do
  @moduledoc false

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Indexing.RecordManager
  alias BeamWeaver.Indexing.Result
  alias BeamWeaver.VectorStore

  @spec apply(term(), term() | nil, map(), Result.t(), term(), keyword()) ::
          {:ok, Result.t()} | {:error, Error.t()}
  def apply(_store, nil, _planned, result, _namespace, _opts), do: {:ok, result}

  def apply(store, manager, planned, result, namespace, opts) do
    cleanup = normalize_cleanup(Keyword.get(opts, :cleanup, :none))

    if cleanup in [nil, :none] do
      {:ok, result}
    else
      with {:ok, stale_ids} <- stale_ids(manager, planned, namespace, cleanup, opts),
           :ok <- maybe_delete_vectors(store, stale_ids, opts),
           :ok <- RecordManager.delete(manager, stale_ids, namespace: namespace) do
        {:ok, %{result | deleted: length(stale_ids), deleted_ids: stale_ids}}
      end
    end
  end

  defp stale_ids(_manager, _planned, _namespace, :none, _opts), do: {:ok, []}

  defp stale_ids(manager, planned, namespace, :incremental, _opts) do
    source_ids = planned.documents |> Enum.map(& &1.source_id) |> Enum.uniq()
    stale_ids_for_sources(manager, namespace, source_ids, planned.current_ids)
  end

  defp stale_ids(manager, planned, namespace, {:scoped, source_ids}, _opts) do
    stale_ids_for_sources(manager, namespace, List.wrap(source_ids), planned.current_ids)
  end

  defp stale_ids(manager, planned, namespace, {:full, scope}, opts) do
    cond do
      is_nil(scope) and not Keyword.get(opts, :force?, false) ->
        {:error,
         Error.new(
           :unsafe_index_cleanup,
           "full cleanup requires an explicit scope or force?: true"
         )}

      is_nil(scope) ->
        with {:ok, records} <- RecordManager.list(manager, namespace: namespace) do
          {:ok,
           records
           |> Enum.reject(&MapSet.member?(planned.current_ids, &1.id))
           |> Enum.map(& &1.id)}
        end

      true ->
        stale_ids_for_sources(manager, namespace, List.wrap(scope), planned.current_ids)
    end
  end

  defp stale_ids(_manager, _planned, _namespace, cleanup, _opts),
    do: {:error, Error.new(:invalid_index_cleanup, "unsupported cleanup mode", %{cleanup: cleanup})}

  defp normalize_cleanup(cleanup) when cleanup in [nil, :none, "none"], do: :none
  defp normalize_cleanup(cleanup) when cleanup in [:incremental, "incremental"], do: :incremental
  defp normalize_cleanup(cleanup) when cleanup in [:full, "full"], do: {:full, nil}
  defp normalize_cleanup(cleanup), do: cleanup

  defp stale_ids_for_sources(manager, namespace, source_ids, current_ids) do
    with {:ok, records} <-
           RecordManager.list(manager, namespace: namespace, source_ids: source_ids) do
      stale =
        records
        |> Enum.reject(&MapSet.member?(current_ids, &1.id))
        |> Enum.map(& &1.id)

      {:ok, stale}
    end
  end

  defp maybe_delete_vectors(_store, [], _opts), do: :ok

  defp maybe_delete_vectors(store, stale_ids, opts),
    do: VectorStore.delete(store, stale_ids, opts)
end
