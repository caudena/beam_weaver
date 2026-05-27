defmodule BeamWeaver.Tracing.Exporters.LangSmith.QueueStore.Ecto do
  @moduledoc false

  @behaviour BeamWeaver.Tracing.Exporters.LangSmith.QueueStore

  alias BeamWeaver.Adapter.Error, as: AdapterError
  alias BeamWeaver.Core.Error

  defstruct repo: nil,
            query_module: Ecto.Adapters.SQL,
            table: "beam_weaver_langsmith_queue",
            serialization: %BeamWeaver.Serialization.Config{}

  def new(opts) do
    %__MODULE__{
      repo: Keyword.fetch!(opts, :repo),
      query_module: Keyword.get(opts, :query_module, Ecto.Adapters.SQL),
      table: Keyword.get(opts, :table, "beam_weaver_langsmith_queue"),
      serialization: BeamWeaver.Serialization.Config.new(Keyword.get(opts, :serialization))
    }
  end

  @impl true
  def put(%__MODULE__{} = store, item) do
    with {:ok, encoded} <-
           BeamWeaver.Adapter.ValueCodec.dump(item, serialization: store.serialization),
         {:ok, _} <-
           query(
             store,
             """
             INSERT INTO #{store.table} (id, item, enqueued_at)
             VALUES ($1, $2, $3)
             ON CONFLICT (id) DO UPDATE SET item = EXCLUDED.item, enqueued_at = EXCLUDED.enqueued_at
             """,
             [item.id, encoded, item.enqueued_at]
           ) do
      :ok
    else
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  @impl true
  def delete(%__MODULE__{} = store, id) do
    case query(store, "DELETE FROM #{store.table} WHERE id = $1", [id]) do
      {:ok, _} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  @impl true
  def list(%__MODULE__{} = store, _opts) do
    case query(store, "SELECT item FROM #{store.table} ORDER BY enqueued_at ASC", []) do
      {:ok, %{rows: rows}} ->
        Enum.reduce_while(rows, [], fn [encoded], acc ->
          case BeamWeaver.Adapter.ValueCodec.load(encoded, serialization: store.serialization) do
            {:ok, item} -> {:cont, [normalize_item(item) | acc]}
            {:error, error} -> {:halt, {:error, error}}
          end
        end)
        |> case do
          {:error, error} -> {:error, error}
          items -> Enum.reverse(items)
        end

      {:error, error} ->
        {:error, error}
    end
  end

  defp query(%__MODULE__{} = store, sql, params) do
    AdapterError.query(store, sql, params,
      type: :langsmith_queue_store_error,
      message: "LangSmith queue store error"
    )
  end

  defp normalize_item(item) when is_map(item) do
    Map.new(item, fn
      {key, value}
      when key in ["id", "event", "run", "opts", "attempts", "retry_at", "enqueued_at"] ->
        {String.to_existing_atom(key), value}

      entry ->
        entry
    end)
  end
end
