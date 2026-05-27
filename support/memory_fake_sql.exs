defmodule BeamWeaver.Memory.FakeSQL do
  @moduledoc false

  def start_link do
    Agent.start_link(fn -> %{} end)
  end

  def query(repo, sql, params) do
    cond do
      String.contains?(sql, "INSERT INTO beam_weaver_memory_items") ->
        [namespace, key, value, metadata, expires_at] = params
        now = DateTime.utc_now()

        item =
          Agent.get_and_update(repo, fn state ->
            created_at =
              case Map.fetch(state, {namespace, key}) do
                {:ok, [_ns, _key, _value, _metadata, created_at, _updated_at, _expires_at]} ->
                  created_at

                :error ->
                  now
              end

            row = [namespace, key, value, metadata, created_at, now, expires_at]
            {row, Map.put(state, {namespace, key}, row)}
          end)

        {:ok, %{rows: [item]}}

      String.contains?(sql, "DELETE FROM beam_weaver_memory_items") and
          String.contains?(sql, "expires_at IS NOT NULL") ->
        now = DateTime.utc_now()

        count =
          Agent.get_and_update(repo, fn state ->
            {expired, fresh} =
              Enum.split_with(state, fn
                {_key, [_namespace, _item_key, _value, _metadata, _created, _updated, expires_at]} ->
                  not is_nil(expires_at) and DateTime.compare(expires_at, now) != :gt
              end)

            {length(expired), Map.new(fresh)}
          end)

        {:ok, %{rows: [], num_rows: count}}

      String.contains?(sql, "DELETE FROM beam_weaver_memory_items") ->
        [namespace, key] = params
        Agent.update(repo, &Map.delete(&1, {namespace, key}))
        {:ok, %{rows: []}}

      String.contains?(sql, "WHERE namespace = $1 AND key = $2") ->
        [namespace, key] = params
        row = Agent.get(repo, &Map.get(&1, {namespace, key}))
        {:ok, %{rows: if(row, do: [row], else: [])}}

      String.contains?(sql, "SELECT DISTINCT namespace") ->
        rows =
          Agent.get(repo, fn state ->
            state
            |> Map.keys()
            |> Enum.map(fn {namespace, _key} -> namespace end)
            |> Enum.uniq()
            |> Enum.sort()
            |> Enum.map(&[&1])
          end)

        {:ok, %{rows: rows}}

      String.contains?(sql, "WHERE namespace[1:array_length") ->
        [prefix] = params

        rows =
          Agent.get(repo, fn state ->
            state
            |> Map.values()
            |> Enum.filter(fn [namespace, _key, _value, _metadata, _created, _updated, _expires] ->
              Enum.take(namespace, length(prefix)) == prefix
            end)
          end)

        {:ok, %{rows: rows}}

      true ->
        {:error, {:unexpected_sql, sql}}
    end
  end
end
