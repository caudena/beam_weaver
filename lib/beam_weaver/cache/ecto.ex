defmodule BeamWeaver.Cache.Ecto do
  @moduledoc """
  Ecto/Postgres cache adapter implementing `BeamWeaver.Cache`.

  ## Options

    * `:repo` - the Ecto repo (required)
    * `:table` - the table name, as given to the migration
    * `:prefix` - the Postgres schema that holds the table, as given to the
      migration's `prefix:`
    * `:serialization` - a `BeamWeaver.Serialization.Config` or its options,
      such as `codec: BeamWeaver.Serialization.Encrypted` with an
      `:encryption_key`
  """

  @behaviour BeamWeaver.Cache

  alias BeamWeaver.Adapter.Error, as: AdapterError
  alias BeamWeaver.Migrations.Postgres.Util
  alias BeamWeaver.Serialization

  defstruct repo: nil,
            query_module: Ecto.Adapters.SQL,
            table: "beam_weaver_cache_entries",
            prefix: nil,
            serialization: %BeamWeaver.Serialization.Config{}

  def new(opts) do
    %__MODULE__{
      repo: Keyword.fetch!(opts, :repo),
      query_module: Keyword.get(opts, :query_module, Ecto.Adapters.SQL),
      table: Keyword.get(opts, :table, "beam_weaver_cache_entries"),
      prefix: Keyword.get(opts, :prefix),
      serialization: BeamWeaver.Serialization.Config.new(Keyword.get(opts, :serialization))
    }
  end

  @impl true
  def lookup(%__MODULE__{} = cache, namespace, key, _opts) do
    sql = """
    SELECT value, metadata, expires_at
    FROM #{table(cache)}
    WHERE namespace = $1 AND key = $2
    """

    case query(cache, sql, [BeamWeaver.Cache.stable_key(namespace), BeamWeaver.Cache.stable_key(key)]) do
      {:ok, %{rows: [[value, metadata, expires_at]]}} ->
        if expired?(expires_at) do
          delete(cache, namespace, key, [])
          :miss
        else
          with {:ok, decoded} <- Serialization.load(value, serialization: cache.serialization),
               do: {:hit, decoded, metadata || %{}}
        end

      {:ok, %{rows: []}} ->
        :miss

      {:error, _error} = error ->
        error
    end
  end

  @impl true
  def put(%__MODULE__{} = cache, namespace, key, value, opts) do
    sql = """
    INSERT INTO #{table(cache)} (namespace, key, value, metadata, expires_at)
    VALUES ($1, $2, $3, $4, $5)
    ON CONFLICT (namespace, key)
    DO UPDATE SET value = EXCLUDED.value,
                  metadata = EXCLUDED.metadata,
                  expires_at = EXCLUDED.expires_at,
                  inserted_at = now()
    """

    with {:ok, encoded} <- Serialization.dump(value, serialization: cache.serialization) do
      params = [
        BeamWeaver.Cache.stable_key(namespace),
        BeamWeaver.Cache.stable_key(key),
        encoded,
        Keyword.get(opts, :metadata, %{}),
        expires_at(Keyword.get(opts, :ttl))
      ]

      with {:ok, _result} <- query(cache, sql, params), do: :ok
    end
  end

  @impl true
  def delete(%__MODULE__{} = cache, namespace, key, _opts) do
    params = [BeamWeaver.Cache.stable_key(namespace), BeamWeaver.Cache.stable_key(key)]

    with {:ok, _result} <- query(cache, "DELETE FROM #{table(cache)} WHERE namespace = $1 AND key = $2", params),
         do: :ok
  end

  @impl true
  def clear(%__MODULE__{} = cache, nil, _opts) do
    with {:ok, _result} <- query(cache, "DELETE FROM #{table(cache)}", []), do: :ok
  end

  def clear(%__MODULE__{} = cache, namespace, _opts) do
    params = [BeamWeaver.Cache.stable_key(namespace)]
    with {:ok, _result} <- query(cache, "DELETE FROM #{table(cache)} WHERE namespace = $1", params), do: :ok
  end

  def sweep_expired(%__MODULE__{} = cache, _opts \\ []) do
    sql = "DELETE FROM #{table(cache)} WHERE expires_at IS NOT NULL AND expires_at <= now()"
    with {:ok, result} <- query(cache, sql, []), do: {:ok, Map.get(result, :num_rows, 0)}
  end

  defp table(%__MODULE__{} = cache), do: Util.qualify(cache.prefix, cache.table)

  defp query(%__MODULE__{} = cache, sql, params),
    do: AdapterError.query(cache, sql, params, :cache_error, "cache adapter error")

  defp expires_at(ttl) when is_integer(ttl) and ttl > 0, do: DateTime.add(DateTime.utc_now(), ttl, :millisecond)
  defp expires_at(_ttl), do: nil

  defp expired?(nil), do: false
  defp expired?(%DateTime{} = expires_at), do: DateTime.compare(DateTime.utc_now(), expires_at) != :lt
end
