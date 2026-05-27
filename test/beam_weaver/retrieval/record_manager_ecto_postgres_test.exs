defmodule BeamWeaver.RecordManagerEctoPostgresTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Indexing.Record
  alias BeamWeaver.Indexing.RecordManager
  alias BeamWeaver.Indexing.RecordManager.EctoPostgres

  test "EctoPostgres record manager uses SQL boundary for put/get/list/delete" do
    {:ok, repo} = Agent.start_link(fn -> %{rows: %{}} end)

    manager =
      EctoPostgres.new(
        repo: repo,
        query_module: __MODULE__.FakeSQL,
        table: "records",
        namespace: :tenant
      )

    record = %Record{
      id: "doc-1",
      source_id: "source-a",
      hash: "hash-a",
      namespace: :tenant,
      metadata: %{rank: 1}
    }

    assert :ok = RecordManager.put(manager, record)

    assert {:ok, %Record{id: "doc-1", source_id: "source-a", metadata: %{rank: 1}}} =
             RecordManager.get(manager, "doc-1")

    assert {:ok, [%Record{id: "doc-1"}]} =
             RecordManager.list(manager, source_ids: ["source-a"])

    assert :ok = RecordManager.delete(manager, ["doc-1"])
    assert {:ok, nil} = RecordManager.get(manager, "doc-1")
  end

  defmodule FakeSQL do
    def query(repo, sql, params) do
      Agent.get_and_update(repo, fn state ->
        cond do
          String.starts_with?(String.trim(sql), "INSERT") ->
            [namespace, id, source_id, hash, metadata] = params

            row = %{
              id: id,
              source_id: source_id,
              hash: hash,
              metadata: metadata,
              updated_at: DateTime.utc_now()
            }

            {{:ok, %{rows: []}}, put_in(state, [:rows, {namespace, id}], row)}

          String.starts_with?(String.trim(sql), "DELETE") ->
            [namespace, ids] = params
            rows = Map.drop(state.rows, Enum.map(ids, &{namespace, &1}))
            {{:ok, %{rows: []}}, %{state | rows: rows}}

          String.starts_with?(String.trim(sql), "SELECT") ->
            [namespace | rest] = params

            rows =
              cond do
                String.contains?(sql, "AND id = $2") ->
                  id = List.first(rest)

                  case Map.get(state.rows, {namespace, id}) do
                    nil -> []
                    row -> [row]
                  end

                String.contains?(sql, "source_id = ANY") ->
                  source_ids = List.first(rest)

                  state.rows
                  |> Enum.flat_map(fn
                    {{^namespace, _id}, row} -> [row]
                    _entry -> []
                  end)
                  |> Enum.filter(&(&1.source_id in source_ids))

                true ->
                  Enum.flat_map(state.rows, fn
                    {{^namespace, _id}, row} -> [row]
                    _entry -> []
                  end)
              end
              |> Enum.map(&[&1.id, &1.source_id, &1.hash, &1.metadata, &1.updated_at])

            result = %{columns: ["id", "source_id", "hash", "metadata", "updated_at"], rows: rows}
            {{:ok, result}, state}

          true ->
            {{:ok, %{rows: []}}, state}
        end
      end)
    end
  end
end
