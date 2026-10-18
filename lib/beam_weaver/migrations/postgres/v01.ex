defmodule BeamWeaver.Migrations.Postgres.Checkpoint.V01 do
  @moduledoc false

  use Ecto.Migration

  alias BeamWeaver.Migrations.Postgres.Util

  def up(%{opts: opts} = spec) do
    prefix = spec[:prefix]
    checkpoints = Util.qualify(prefix, opts.checkpoints_table)
    writes = Util.qualify(prefix, opts.writes_table)

    execute("""
    CREATE TABLE IF NOT EXISTS #{checkpoints} (
      thread_id text NOT NULL,
      checkpoint_ns text NOT NULL DEFAULT '',
      checkpoint_id text NOT NULL,
      parent_checkpoint_id text,
      checkpoint jsonb NOT NULL,
      metadata jsonb NOT NULL DEFAULT '{}',
      inserted_at timestamptz NOT NULL DEFAULT now(),
      PRIMARY KEY (thread_id, checkpoint_ns, checkpoint_id)
    )
    """)

    execute("""
    CREATE TABLE IF NOT EXISTS #{writes} (
      thread_id text NOT NULL,
      checkpoint_ns text NOT NULL DEFAULT '',
      checkpoint_id text NOT NULL,
      task_id text NOT NULL,
      write_index integer NOT NULL,
      channel text NOT NULL,
      value jsonb NOT NULL,
      task_path text NOT NULL DEFAULT '',
      inserted_at timestamptz NOT NULL DEFAULT now(),
      PRIMARY KEY (thread_id, checkpoint_ns, checkpoint_id, task_id, write_index)
    )
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS #{Util.index(opts.checkpoints_table, "thread_idx")}
    ON #{checkpoints} (thread_id, checkpoint_ns, checkpoint_id DESC)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS #{Util.index(opts.checkpoints_table, "metadata_run_id_idx")}
    ON #{checkpoints} ((metadata->>'run_id'))
    """)
  end

  def down(%{opts: opts} = spec) do
    prefix = spec[:prefix]
    execute("DROP TABLE IF EXISTS #{Util.qualify(prefix, opts.writes_table)}")
    execute("DROP TABLE IF EXISTS #{Util.qualify(prefix, opts.checkpoints_table)}")
  end
end

defmodule BeamWeaver.Migrations.Postgres.Memory.V01 do
  @moduledoc false

  use Ecto.Migration

  alias BeamWeaver.Migrations.Postgres.Util

  def up(%{opts: opts} = spec) do
    table = Util.qualify(spec[:prefix], opts.table)

    execute("""
    CREATE TABLE IF NOT EXISTS #{table} (
      namespace text[] NOT NULL,
      key text NOT NULL,
      value jsonb NOT NULL,
      metadata jsonb NOT NULL DEFAULT '{}',
      created_at timestamptz NOT NULL DEFAULT now(),
      updated_at timestamptz NOT NULL DEFAULT now(),
      expires_at timestamptz,
      PRIMARY KEY (namespace, key)
    )
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS #{Util.index(opts.table, "namespace_idx")}
    ON #{table} USING gin (namespace)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS #{Util.index(opts.table, "metadata_idx")}
    ON #{table} USING gin (metadata)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS #{Util.index(opts.table, "expires_at_idx")}
    ON #{table} (expires_at)
    """)
  end

  def down(spec), do: Util.drop_table(spec)
end

defmodule BeamWeaver.Migrations.Postgres.Cache.V01 do
  @moduledoc false

  use Ecto.Migration

  alias BeamWeaver.Migrations.Postgres.Util

  def up(%{opts: opts} = spec) do
    table = Util.qualify(spec[:prefix], opts.table)

    execute("""
    CREATE TABLE IF NOT EXISTS #{table} (
      namespace bytea NOT NULL,
      key bytea NOT NULL,
      value bytea NOT NULL,
      metadata jsonb NOT NULL DEFAULT '{}',
      inserted_at timestamptz NOT NULL DEFAULT now(),
      expires_at timestamptz,
      PRIMARY KEY (namespace, key)
    )
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS #{Util.index(opts.table, "expires_at_idx")}
    ON #{table} (expires_at)
    """)
  end

  def down(spec), do: Util.drop_table(spec)
end

defmodule BeamWeaver.Migrations.Postgres.VectorStore.V01 do
  @moduledoc false

  use Ecto.Migration

  alias BeamWeaver.Migrations.Postgres.Util

  def up(%{opts: opts} = spec) do
    table = Util.qualify(spec[:prefix], opts.table)

    if opts.create_extension? do
      execute("CREATE EXTENSION IF NOT EXISTS vector")
    end

    execute("""
    CREATE TABLE IF NOT EXISTS #{table} (
      id text NOT NULL,
      namespace text NOT NULL,
      content text NOT NULL,
      metadata jsonb NOT NULL DEFAULT '{}',
      embedding vector(#{opts.dimensions}) NOT NULL,
      created_at timestamptz NOT NULL DEFAULT now(),
      updated_at timestamptz NOT NULL DEFAULT now(),
      PRIMARY KEY (namespace, id)
    )
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS #{Util.index(opts.table, "namespace_idx")}
    ON #{table} (namespace)
    """)

    if opts.index, do: execute(index_sql(table, opts))
  end

  def down(spec), do: Util.drop_table(spec)

  defp index_sql(table, %{index: :hnsw} = opts) do
    with_opts =
      case Keyword.get(opts.index_opts, :with, Keyword.take(opts.index_opts, [:m, :ef_construction])) do
        with_opts when is_binary(with_opts) -> with_opts
        [_ | _] = with_opts -> Enum.map_join(with_opts, ", ", fn {key, value} -> "#{key} = #{value}" end)
        _default -> "m = 16, ef_construction = 64"
      end

    """
    CREATE INDEX IF NOT EXISTS #{Util.index(opts.table, "embedding_hnsw_idx")}
    ON #{table}
    USING hnsw (embedding #{Util.vector_opclass(opts)})
    WITH (#{with_opts})
    """
  end

  defp index_sql(table, opts) do
    lists = Keyword.get(opts.index_opts, :lists, 100)

    """
    CREATE INDEX IF NOT EXISTS #{Util.index(opts.table, "embedding_ivfflat_idx")}
    ON #{table}
    USING ivfflat (embedding #{Util.vector_opclass(opts)})
    WITH (lists = #{lists})
    """
  end
end

defmodule BeamWeaver.Migrations.Postgres.RecordManager.V01 do
  @moduledoc false

  use Ecto.Migration

  alias BeamWeaver.Migrations.Postgres.Util

  def up(%{opts: opts} = spec) do
    table = Util.qualify(spec[:prefix], opts.table)

    execute("""
    CREATE TABLE IF NOT EXISTS #{table} (
      namespace text NOT NULL,
      id text NOT NULL,
      source_id text NOT NULL,
      hash text NOT NULL,
      metadata jsonb NOT NULL DEFAULT '{}',
      updated_at timestamptz NOT NULL DEFAULT now(),
      PRIMARY KEY (namespace, id)
    )
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS #{Util.index(opts.table, "source_idx")}
    ON #{table} (namespace, source_id)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS #{Util.index(opts.table, "updated_at_idx")}
    ON #{table} (updated_at)
    """)
  end

  def down(spec), do: Util.drop_table(spec)
end
