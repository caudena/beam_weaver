defmodule BeamWeaver.Migrations.Postgres.Checkpoint.Ordering do
  @moduledoc false

  use Ecto.Migration

  alias BeamWeaver.Migrations.Postgres.Util

  def up(%{opts: opts} = spec) do
    prefix = spec[:prefix]
    table = Util.qualify(prefix, opts.checkpoints_table)

    execute("ALTER TABLE #{table} ADD COLUMN IF NOT EXISTS commit_order bigint")

    execute("""
    WITH ordered AS (
      SELECT thread_id, checkpoint_ns, checkpoint_id,
             row_number() OVER (
               PARTITION BY thread_id, checkpoint_ns
               ORDER BY inserted_at, checkpoint_id
             ) AS position
      FROM #{table}
      WHERE commit_order IS NULL
    )
    UPDATE #{table} AS checkpoints
    SET commit_order = ordered.position
    FROM ordered
    WHERE checkpoints.thread_id = ordered.thread_id
      AND checkpoints.checkpoint_ns = ordered.checkpoint_ns
      AND checkpoints.checkpoint_id = ordered.checkpoint_id
    """)

    execute("ALTER TABLE #{table} ALTER COLUMN commit_order SET NOT NULL")

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS #{Util.index(prefix, opts.checkpoints_table, "commit_order_idx")}
    ON #{table} (thread_id, checkpoint_ns, commit_order)
    """)
  end

  def down(%{opts: opts} = spec) do
    table = Util.qualify(spec[:prefix], opts.checkpoints_table)
    execute("ALTER TABLE #{table} DROP COLUMN IF EXISTS commit_order")
  end
end
