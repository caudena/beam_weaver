defmodule BeamWeaver.Cache.ETS do
  @moduledoc """
  ETS cache adapter for local workflows, tests, and supervised applications.
  """

  @behaviour BeamWeaver.Cache

  defstruct [:table, :max_entries]

  @type t :: %__MODULE__{table: :ets.tid(), max_entries: pos_integer() | nil}

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    visibility = Keyword.get(opts, :visibility, :public)
    max_entries = Keyword.get(opts, :max_entries, Keyword.get(opts, :maxsize))

    if not is_nil(max_entries) and (not is_integer(max_entries) or max_entries <= 0) do
      raise ArgumentError, "max_entries must be a positive integer"
    end

    %__MODULE__{table: :ets.new(:beam_weaver_cache, [:set, visibility]), max_entries: max_entries}
  end

  @impl true
  def lookup(%__MODULE__{} = cache, namespace, key, _opts) do
    case :ets.lookup(cache.table, {namespace, key}) do
      [{{^namespace, ^key}, entry}] ->
        if expired?(entry) do
          :ets.delete(cache.table, {namespace, key})
          :miss
        else
          {:hit, entry.value, entry.metadata}
        end

      [] ->
        :miss
    end
  end

  @impl true
  def put(%__MODULE__{} = cache, namespace, key, value, opts) do
    now = System.system_time(:millisecond)
    ttl = Keyword.get(opts, :ttl)
    expires_at = if is_integer(ttl) and ttl > 0, do: now + ttl, else: nil

    entry = %{
      value: value,
      metadata: Keyword.get(opts, :metadata, %{}),
      inserted_at: now,
      expires_at: expires_at
    }

    evict_oldest_if_needed(cache, {namespace, key})
    :ets.insert(cache.table, {{namespace, key}, entry})
    :ok
  end

  @impl true
  def delete(%__MODULE__{} = cache, namespace, key, _opts) do
    :ets.delete(cache.table, {namespace, key})
    :ok
  end

  @impl true
  def clear(%__MODULE__{} = cache, nil, _opts) do
    :ets.delete_all_objects(cache.table)
    :ok
  end

  def clear(%__MODULE__{} = cache, namespace, _opts) do
    for {{^namespace, key}, _entry} <- :ets.tab2list(cache.table) do
      :ets.delete(cache.table, {namespace, key})
    end

    :ok
  end

  defp expired?(%{expires_at: nil}), do: false
  defp expired?(%{expires_at: expires_at}), do: System.system_time(:millisecond) >= expires_at

  defp evict_oldest_if_needed(%__MODULE__{max_entries: nil}, _new_key), do: :ok

  defp evict_oldest_if_needed(%__MODULE__{} = cache, new_key) do
    entries = :ets.tab2list(cache.table)

    if length(entries) >= cache.max_entries and not Enum.any?(entries, &match?({^new_key, _}, &1)) do
      entries
      |> Enum.min_by(fn {_key, entry} -> Map.get(entry, :inserted_at, 0) end)
      |> elem(0)
      |> then(&:ets.delete(cache.table, &1))
    end

    :ok
  end
end
