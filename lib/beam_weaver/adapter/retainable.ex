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
    now = System.system_time(:millisecond)
    cutoff = cutoff_ms(now, opts)

    entries =
      cache.table
      |> :ets.tab2list()
      |> Enum.filter(fn {{entry_namespace, _key}, _entry} ->
        is_nil(namespace) or entry_namespace == namespace
      end)

    age_deleted =
      entries
      |> Enum.reduce(0, fn
        {{entry_namespace, key}, %{inserted_at: inserted_at}}, acc
        when is_integer(cutoff) and is_integer(inserted_at) and inserted_at <= cutoff ->
          :ets.delete(cache.table, {entry_namespace, key})
          acc + 1

        _entry, acc ->
          acc
      end)

    limit_deleted =
      cache.table
      |> :ets.tab2list()
      |> Enum.filter(fn {{entry_namespace, _key}, _entry} ->
        is_nil(namespace) or entry_namespace == namespace
      end)
      |> prune_to_limit(cache.table, Keyword.get(opts, :max_entries), &cache_inserted_at/1)

    {:ok, age_deleted + limit_deleted}
  end

  defp cutoff_ms(_now, opts) do
    cond do
      is_integer(Keyword.get(opts, :older_than_ms)) ->
        Keyword.fetch!(opts, :older_than_ms)

      is_integer(Keyword.get(opts, :max_age_ms)) ->
        System.system_time(:millisecond) - Keyword.fetch!(opts, :max_age_ms)

      true ->
        nil
    end
  end

  defp cache_inserted_at({{_namespace, _key}, entry}), do: Map.get(entry, :inserted_at, 0)

  defp prune_to_limit(_entries, _table, nil, _time_fun), do: 0
  defp prune_to_limit(_entries, _table, max_entries, _time_fun) when max_entries < 0, do: 0

  defp prune_to_limit(entries, table, max_entries, time_fun) when is_integer(max_entries) do
    entries
    |> Enum.sort_by(time_fun, :desc)
    |> Enum.drop(max_entries)
    |> Enum.reduce(0, fn {{namespace, key}, _entry}, acc ->
      :ets.delete(table, {namespace, key})
      acc + 1
    end)
  end
end

defimpl BeamWeaver.Adapter.Retainable, for: BeamWeaver.Memory.ETS do
  def prune(store, opts) do
    namespace = Keyword.get(opts, :namespace)
    cutoff = cutoff_datetime(opts)

    entries =
      store.items
      |> :ets.tab2list()
      |> Enum.filter(fn {{entry_namespace, _key}, _entry} ->
        is_nil(namespace) or entry_namespace == namespace
      end)

    age_deleted =
      entries
      |> Enum.reduce(0, fn
        {{entry_namespace, key}, %{updated_at: updated_at}}, acc
        when not is_nil(cutoff) ->
          if DateTime.compare(updated_at, cutoff) != :gt do
            :ets.delete(store.items, {entry_namespace, key})
            acc + 1
          else
            acc
          end

        _entry, acc ->
          acc
      end)

    limit_deleted =
      store.items
      |> :ets.tab2list()
      |> Enum.filter(fn {{entry_namespace, _key}, _entry} ->
        is_nil(namespace) or entry_namespace == namespace
      end)
      |> prune_to_limit(store.items, Keyword.get(opts, :max_entries))

    {:ok, age_deleted + limit_deleted}
  end

  defp cutoff_datetime(opts) do
    case Keyword.get(opts, :older_than) do
      %DateTime{} = value ->
        value

      _other ->
        if is_integer(Keyword.get(opts, :max_age_ms)) do
          DateTime.add(DateTime.utc_now(), -Keyword.fetch!(opts, :max_age_ms), :millisecond)
        end
    end
  end

  defp prune_to_limit(_entries, _table, nil), do: 0
  defp prune_to_limit(_entries, _table, max_entries) when max_entries < 0, do: 0

  defp prune_to_limit(entries, table, max_entries) when is_integer(max_entries) do
    entries
    |> Enum.sort_by(fn {_key, item} -> item.updated_at end, {:desc, DateTime})
    |> Enum.drop(max_entries)
    |> Enum.reduce(0, fn {{namespace, key}, _item}, acc ->
      :ets.delete(table, {namespace, key})
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
