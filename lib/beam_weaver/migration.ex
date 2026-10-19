defmodule BeamWeaver.Migrations do
  @moduledoc """
  Versioned database migrations for BeamWeaver durable adapters.

  Call `up/1` and `down/1` from application-owned `Ecto.Migration` modules.
  [Storage](storage.md#postgresql-setup) shows repository startup, a complete
  migration, and execution against the database. Migration functions require
  Ecto's migration runner; they are not standalone table-creation functions.

  The default adapter is `:checkpoint`. Pass `adapters: :all` to install every
  durable adapter table. The repository selects the migration dialect:
  PostgreSQL supports all durable adapters, while SQLite currently supports
  `:checkpoint` only.

  On PostgreSQL, `prefix:` puts the tables in that schema, which `up/1`
  creates unless `create_schema: false` is given; pass the same `:prefix` to
  the adapters. A `:vector_store` entry takes `dimensions:`, `distance:`,
  `index:` (`:ivfflat`, `:hnsw`, or `false` for no index, which embeddings of
  more than 2,000 dimensions need) and `index_opts:`.

  Memory schema version 2 keeps each record's lifetime. A record already
  stored gets the time from its last write to its expiry. A store created
  with `refresh_on_read?: true` moved the expiry of the records it read, so
  for those records that time is longer than their lifetime: give the
  `:memory` entry that store's `default_ttl:`, in minutes, to cap it, as in
  `up(adapters: [{:memory, default_ttl: 60 * 24}])`.
  """

  use Ecto.Migration

  @sqlite_adapter :"Elixir.Ecto.Adapters.SQLite3"

  @doc """
  Migrates selected BeamWeaver adapter tables up to their current version.
  """
  @spec up(keyword()) :: :ok
  def up(opts \\ []) when is_list(opts), do: migrator(opts).up(opts)

  @doc """
  Migrates selected BeamWeaver adapter tables down to the requested version.
  """
  @spec down(keyword()) :: :ok
  def down(opts \\ []) when is_list(opts), do: migrator(opts).down(opts)

  @doc """
  Returns the current migration version for selected adapters.
  """
  @spec current_version(keyword()) :: non_neg_integer() | map()
  def current_version(opts \\ []) when is_list(opts) do
    if Keyword.has_key?(opts, :repo) do
      migrator(opts).current_version(opts)
    else
      BeamWeaver.Migrations.Postgres.current_version(opts)
    end
  end

  @doc """
  Returns the migrated database version for selected adapters.
  """
  @spec migrated_version(keyword()) :: non_neg_integer() | map()
  def migrated_version(opts \\ []) when is_list(opts), do: migrator(opts).migrated_version(opts)

  @doc """
  Raises when selected adapter tables are missing or behind the current version.
  """
  @spec verify_migrated!(keyword()) :: :ok
  def verify_migrated!(opts \\ []) when is_list(opts) do
    opts = Keyword.put_new_lazy(opts, :repo, &repo/0)
    migrator(opts).verify_migrated!(opts)
  end

  defp migrator(opts) do
    repo = Keyword.get_lazy(opts, :repo, &repo/0)

    case repo.__adapter__() do
      Ecto.Adapters.Postgres ->
        BeamWeaver.Migrations.Postgres

      @sqlite_adapter ->
        BeamWeaver.Migrations.SQLite

      adapter ->
        raise ArgumentError, "unsupported BeamWeaver migration adapter: #{inspect(adapter)}"
    end
  end
end
