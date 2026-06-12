defmodule BeamWeaver.Migrations do
  @moduledoc """
  Versioned database migrations for BeamWeaver durable adapters.

  Use this module from application-owned Ecto migrations:

      def up do
        BeamWeaver.Migrations.up(adapters: [:checkpoint, :memory])
      end

      def down do
        BeamWeaver.Migrations.down(adapters: [:memory, :checkpoint], version: 1)
      end

  The default adapter is `:checkpoint`. Pass `adapters: :all` to install every
  durable adapter table.
  """

  use Ecto.Migration

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

      adapter ->
        raise ArgumentError, "unsupported BeamWeaver migration adapter: #{inspect(adapter)}"
    end
  end
end
