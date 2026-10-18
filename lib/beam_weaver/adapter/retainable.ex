defprotocol BeamWeaver.Adapter.Retainable do
  @moduledoc """
  Optional retention/pruning capability for adapters.
  """

  @fallback_to_any true

  @spec prune(term(), keyword()) :: {:ok, non_neg_integer()} | {:error, BeamWeaver.Core.Error.t()}
  def prune(adapter, opts)
end

defimpl BeamWeaver.Adapter.Retainable, for: BeamWeaver.Cache.ETS do
  def prune(cache, opts) do
    namespace = Keyword.get(opts, :namespace)
    cutoff = cutoff_ms(opts)

    aged =
      for {key, %{inserted_at: inserted_at}} <- entries(cache.table, namespace),
          is_integer(cutoff) and is_integer(inserted_at) and inserted_at <= cutoff,
          do: :ets.delete(cache.table, key)

    limit_deleted = cache.table |> entries(namespace) |> prune_to_limit(cache.table, Keyword.get(opts, :max_entries))
    {:ok, length(aged) + limit_deleted}
  end

  defp entries(table, namespace) do
    for {{entry_namespace, _key}, _entry} = entry <- :ets.tab2list(table),
        is_nil(namespace) or entry_namespace == namespace,
        do: entry
  end

  defp cutoff_ms(opts) do
    cond do
      is_integer(Keyword.get(opts, :older_than_ms)) -> Keyword.fetch!(opts, :older_than_ms)
      is_integer(Keyword.get(opts, :max_age_ms)) -> System.system_time(:millisecond) - Keyword.fetch!(opts, :max_age_ms)
      true -> nil
    end
  end

  defp prune_to_limit(_entries, _table, nil), do: 0
  defp prune_to_limit(_entries, _table, max_entries) when max_entries < 0, do: 0

  defp prune_to_limit(entries, table, max_entries) when is_integer(max_entries) do
    entries
    |> Enum.sort_by(fn {_key, entry} -> Map.get(entry, :inserted_at, 0) end, :desc)
    |> Enum.drop(max_entries)
    |> Enum.reduce(0, fn {key, _entry}, acc ->
      :ets.delete(table, key)
      acc + 1
    end)
  end
end

defimpl BeamWeaver.Adapter.Retainable, for: BeamWeaver.Memory.Ecto do
  def prune(store, opts), do: BeamWeaver.Memory.Ecto.prune(store, opts)
end

defimpl BeamWeaver.Adapter.Retainable, for: BeamWeaver.Memory.ETS do
  def prune(store, opts) do
    namespace = Keyword.get(opts, :namespace)
    cutoff = BeamWeaver.Memory.Query.prune_cutoff(opts)

    aged =
      for {{entry_namespace, key}, %{updated_at: updated_at}} <- entries(store.items, namespace),
          not is_nil(cutoff) and DateTime.compare(updated_at, cutoff) != :gt,
          do: BeamWeaver.Memory.ETS.delete(store, entry_namespace, key)

    limit_deleted = store.items |> entries(namespace) |> prune_to_limit(store, Keyword.get(opts, :max_entries))
    {:ok, length(aged) + limit_deleted}
  end

  defp entries(table, namespace) do
    for {{entry_namespace, _key}, _entry} = entry <- :ets.tab2list(table),
        is_nil(namespace) or entry_namespace == namespace,
        do: entry
  end

  defp prune_to_limit(_entries, _store, nil), do: 0
  defp prune_to_limit(_entries, _store, max_entries) when max_entries < 0, do: 0

  defp prune_to_limit(entries, store, max_entries) when is_integer(max_entries) do
    entries
    |> Enum.sort_by(fn {_key, item} -> item.updated_at end, {:desc, DateTime})
    |> Enum.drop(max_entries)
    |> Enum.reduce(0, fn {{namespace, key}, _item}, acc ->
      BeamWeaver.Memory.ETS.delete(store, namespace, key)
      acc + 1
    end)
  end
end

defimpl BeamWeaver.Adapter.Retainable, for: Any do
  alias BeamWeaver.Core.Error

  def prune(adapter, _opts) do
    {:error,
     Error.new(:unsupported_operation, "adapter does not support retention pruning", %{
       adapter: inspect(adapter)
     })}
  end
end
