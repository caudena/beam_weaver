defmodule BeamWeaver.Migrations.Postgres.Memory.V02 do
  @moduledoc false

  use Ecto.Migration

  alias BeamWeaver.Migrations.Postgres.Util

  @lifetime "EXTRACT(EPOCH FROM (expires_at - updated_at)) / 60"

  # Each record keeps its lifetime, so that reading it can start it again.
  # Existing records get the time from their last write to their expiry. The
  # version 1 store's refresh on read moved the expiry and left the write time
  # alone, so a record it refreshed would get a longer lifetime than it had:
  # `default_ttl:`, the minutes that store refreshed records for, caps it.
  def up(%{opts: opts} = spec) do
    table = Util.qualify(spec[:prefix], opts.table)

    execute("ALTER TABLE #{table} ADD COLUMN IF NOT EXISTS ttl_minutes double precision")

    execute("""
    UPDATE #{table}
    SET ttl_minutes = #{lifetime(opts)}
    WHERE expires_at IS NOT NULL AND ttl_minutes IS NULL
    """)
  end

  def down(%{opts: opts} = spec) do
    execute("ALTER TABLE #{Util.qualify(spec[:prefix], opts.table)} DROP COLUMN IF EXISTS ttl_minutes")
  end

  defp lifetime(%{default_ttl: default_ttl}) when is_number(default_ttl), do: "LEAST(#{@lifetime}, #{default_ttl})"
  defp lifetime(_opts), do: @lifetime
end
