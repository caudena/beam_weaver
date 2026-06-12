defmodule BeamWeaver.Cache.Ecto do
  @moduledoc """
  Ecto/Postgres cache adapter implementing `BeamWeaver.Cache`.
  """

  @behaviour BeamWeaver.Cache

  alias BeamWeaver.Adapter.Error, as: AdapterError
  alias BeamWeaver.Core.Error

  defstruct repo: nil,
            query_module: Ecto.Adapters.SQL,
            table: "beam_weaver_cache_entries",
            serialization: %BeamWeaver.Serialization.Config{}

  def new(opts) do
    %__MODULE__{
      repo: Keyword.fetch!(opts, :repo),
      query_module: Keyword.get(opts, :query_module, Ecto.Adapters.SQL),
      table: Keyword.get(opts, :table, "beam_weaver_cache_entries"),
      serialization: BeamWeaver.Serialization.Config.new(Keyword.get(opts, :serialization))
    }
  end

  @impl true
  def lookup(%__MODULE__{} = cache, namespace, key, _opts) do
    sql = """
    SELECT value, metadata, expires_at
    FROM #{cache.table}
    WHERE namespace = $1 AND key = $2
    """

    case query(cache, sql, [BeamWeaver.Cache.stable_key(namespace), BeamWeaver.Cache.stable_key(key)]) do
      {:ok, %{rows: [[value, metadata, expires_at]]}} ->
        if expired?(expires_at) do
          delete(cache, namespace, key, [])
          :miss
        else
          case decode_value(cache, value) do
            {:ok, decoded} -> {:hit, decoded, metadata || %{}}
            {:error, %Error{} = error} -> {:error, error}
          end
        end

      {:ok, %{rows: []}} ->
        :miss

      {:error, error} ->
        {:error, normalize_error(error)}
    end
  end

  @impl true
  def put(%__MODULE__{} = cache, namespace, key, value, opts) do
    sql = """
    INSERT INTO #{cache.table} (namespace, key, value, metadata, expires_at)
    VALUES ($1, $2, $3, $4, $5)
    ON CONFLICT (namespace, key)
    DO UPDATE SET value = EXCLUDED.value,
                  metadata = EXCLUDED.metadata,
                  expires_at = EXCLUDED.expires_at,
                  inserted_at = now()
    """

    with {:ok, encoded} <- encode_value(cache, value) do
      params = [
        BeamWeaver.Cache.stable_key(namespace),
        BeamWeaver.Cache.stable_key(key),
        encoded,
        Keyword.get(opts, :metadata, %{}),
        expires_at(Keyword.get(opts, :ttl))
      ]

      case query(cache, sql, params) do
        {:ok, _result} -> :ok
        {:error, error} -> {:error, normalize_error(error)}
      end
    end
  end

  @impl true
  def delete(%__MODULE__{} = cache, namespace, key, _opts) do
    case query(cache, "DELETE FROM #{cache.table} WHERE namespace = $1 AND key = $2", [
           BeamWeaver.Cache.stable_key(namespace),
           BeamWeaver.Cache.stable_key(key)
         ]) do
      {:ok, _result} -> :ok
      {:error, error} -> {:error, normalize_error(error)}
    end
  end

  @impl true
  def clear(%__MODULE__{} = cache, nil, _opts) do
    case query(cache, "DELETE FROM #{cache.table}", []) do
      {:ok, _result} -> :ok
      {:error, error} -> {:error, normalize_error(error)}
    end
  end

  def clear(%__MODULE__{} = cache, namespace, _opts) do
    case query(cache, "DELETE FROM #{cache.table} WHERE namespace = $1", [
           BeamWeaver.Cache.stable_key(namespace)
         ]) do
      {:ok, _result} -> :ok
      {:error, error} -> {:error, normalize_error(error)}
    end
  end

  def sweep_expired(%__MODULE__{} = cache, _opts \\ []) do
    case query(
           cache,
           "DELETE FROM #{cache.table} WHERE expires_at IS NOT NULL AND expires_at <= now()",
           []
         ) do
      {:ok, result} -> {:ok, Map.get(result, :num_rows, 0)}
      {:error, error} -> {:error, normalize_error(error)}
    end
  end

  defp query(%__MODULE__{} = cache, sql, params) do
    AdapterError.query(cache, sql, params,
      type: :cache_error,
      message: "cache adapter error"
    )
  end

  defp encode_value(%__MODULE__{} = cache, value) do
    BeamWeaver.Adapter.ValueCodec.dump(value, serialization: cache.serialization)
  end

  defp decode_value(%__MODULE__{} = cache, binary) do
    BeamWeaver.Adapter.ValueCodec.load(binary, serialization: cache.serialization)
  end

  defp expires_at(nil), do: nil

  defp expires_at(ttl) when is_integer(ttl) and ttl > 0,
    do: DateTime.add(DateTime.utc_now(), ttl, :millisecond)

  defp expires_at(_ttl), do: nil

  defp expired?(nil), do: false

  defp expired?(%DateTime{} = expires_at),
    do: DateTime.compare(DateTime.utc_now(), expires_at) != :lt

  defp expired?(_expires_at), do: false

  defp normalize_error(%Error{} = error), do: error
end
