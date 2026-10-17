defmodule BeamWeaver.Indexing.RecordManager.ETS do
  @moduledoc """
  ETS-backed indexing record manager for tests and local deployments.
  """

  use BeamWeaver.Indexing.RecordManager

  alias BeamWeaver.Indexing.Record
  alias BeamWeaver.Indexing.RecordManager

  defstruct [:table, namespace: :default]

  def new(opts \\ []) do
    table =
      Keyword.get_lazy(opts, :table, fn ->
        :ets.new(:beam_weaver_indexing_records, [:set, :public, {:read_concurrency, true}])
      end)

    %__MODULE__{table: table, namespace: Keyword.get(opts, :namespace, :default)}
  end

  @impl true
  def get(%__MODULE__{} = manager, id, opts) do
    namespace = Keyword.get(opts, :namespace, manager.namespace)

    case :ets.lookup(manager.table, {namespace, id}) do
      [{_key, record}] -> {:ok, record}
      [] -> {:ok, nil}
    end
  end

  @impl true
  def put(%__MODULE__{} = manager, %Record{} = record, opts) do
    namespace = Keyword.get(opts, :namespace, RecordManager.record_namespace(manager, record.namespace))
    record = %{record | namespace: namespace, updated_at: record.updated_at || DateTime.utc_now()}
    :ets.insert(manager.table, {{namespace, record.id}, record})
    :ok
  end

  @impl true
  def list(%__MODULE__{} = manager, opts) do
    namespace = Keyword.get(opts, :namespace, manager.namespace)
    source_ids = opts |> Keyword.get(:source_ids) |> RecordManager.normalize_source_ids()

    records =
      for {{^namespace, _id}, %Record{} = record} <- :ets.tab2list(manager.table),
          source_ids == nil or record.source_id in source_ids,
          do: record

    {:ok, records}
  end

  @impl true
  def delete(%__MODULE__{} = manager, ids, opts) do
    namespace = Keyword.get(opts, :namespace, manager.namespace)
    Enum.each(ids, &:ets.delete(manager.table, {namespace, &1}))
    :ok
  end
end
