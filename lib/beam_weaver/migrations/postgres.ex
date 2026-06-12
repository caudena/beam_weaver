defmodule BeamWeaver.Migrations.Postgres do
  @moduledoc false

  use Ecto.Migration

  alias BeamWeaver.Migrations.Postgres.Util

  @initial_version 1
  @default_prefix "public"

  @adapter_order [
    :checkpoint,
    :memory,
    :cache,
    :vector_store,
    :record_manager
  ]

  @current_versions Map.new(@adapter_order, &{&1, 1})

  @doc false
  def initial_version, do: @initial_version

  @doc false
  def current_version(opts \\ []) do
    opts
    |> normalize_specs()
    |> versions_result(&Map.fetch!(@current_versions, &1.key))
  end

  def up(opts \\ []) do
    opts = with_defaults(opts)
    maybe_create_schema(opts)

    for spec <- normalize_specs(opts) do
      initial = migrated_version(opts, spec)
      target = Keyword.get(opts, :version, Map.fetch!(@current_versions, spec.key))

      cond do
        initial == :infinity ->
          :ok

        initial == 0 ->
          change(spec, @initial_version..target, :up)
          record_version(opts, spec, target)

        initial < target ->
          change(spec, (initial + 1)..target, :up)
          record_version(opts, spec, target)

        true ->
          :ok
      end
    end

    :ok
  end

  def down(opts \\ []) do
    opts = with_defaults(opts)

    for spec <- normalize_specs(opts) do
      initial = migrated_version(opts, spec)
      target = Keyword.get(opts, :version, @initial_version)

      cond do
        initial in [0, :infinity] ->
          :ok

        initial >= target ->
          change(spec, initial..target//-1, :down)
          record_version(opts, spec, target - 1)

        true ->
          :ok
      end
    end

    :ok
  end

  def migrated_version(opts \\ []) do
    opts = with_defaults(opts)

    opts
    |> normalize_specs()
    |> versions_result(&migrated_version(opts, &1))
  end

  def verify_migrated!(opts \\ []) do
    opts = with_defaults(opts)

    for spec <- normalize_specs(opts) do
      current = Map.fetch!(@current_versions, spec.key)
      version = migrated_version(opts, spec)

      cond do
        version == 0 ->
          raise RuntimeError, """
          BeamWeaver #{spec.key} migrations have not been run. The #{spec.primary_table} table does not exist or has no migration version.

          Run migrations before using this adapter:

              defmodule MyApp.Repo.Migrations.AddBeamWeaver#{Macro.camelize(to_string(spec.key))} do
                use Ecto.Migration

                def up, do: BeamWeaver.Migrations.up(adapters: [#{inspect(spec.adapter_spec)}])
                def down, do: BeamWeaver.Migrations.down(adapters: [#{inspect(spec.adapter_spec)}], version: 1)
              end
          """

        version != :infinity and version < current ->
          raise RuntimeError, """
          BeamWeaver #{spec.key} migrations are outdated. Found version #{version}, but version #{current} is required.

          Run migrations to update:

              BeamWeaver.Migrations.up(adapters: [#{inspect(spec.adapter_spec)}])
          """

        true ->
          :ok
      end
    end

    :ok
  end

  defp change(spec, range, direction) do
    for index <- range do
      pad_idx = String.pad_leading(to_string(index), 2, "0")

      spec.key
      |> module_base()
      |> Module.concat("V#{pad_idx}")
      |> apply(direction, [spec])
    end
  end

  defp module_base(:checkpoint), do: BeamWeaver.Migrations.Postgres.Checkpoint
  defp module_base(:memory), do: BeamWeaver.Migrations.Postgres.Memory
  defp module_base(:cache), do: BeamWeaver.Migrations.Postgres.Cache
  defp module_base(:vector_store), do: BeamWeaver.Migrations.Postgres.VectorStore
  defp module_base(:record_manager), do: BeamWeaver.Migrations.Postgres.RecordManager

  defp migrated_version(opts, spec) do
    repo = Keyword.get_lazy(opts, :repo, &repo/0)

    query = """
    SELECT pg_catalog.obj_description(to_regclass($1), 'pg_class')
    """

    case repo.query(query, [Util.regclass(opts[:prefix], spec.primary_table)], log: false) do
      {:ok, %{rows: [["∞"]]}} -> :infinity
      {:ok, %{rows: [[version]]}} when is_binary(version) -> parse_version(version)
      _other -> 0
    end
  end

  defp parse_version(version) do
    case Integer.parse(version) do
      {integer, ""} -> integer
      _other -> 0
    end
  end

  defp record_version(_opts, _spec, 0), do: :ok

  defp record_version(opts, spec, version) do
    table = Util.qualify(opts[:prefix], spec.primary_table)
    execute("COMMENT ON TABLE #{table} IS '#{Util.escaped_comment(version)}'")
  end

  defp maybe_create_schema(opts) do
    prefix = Keyword.fetch!(opts, :prefix)
    create_schema? = Keyword.fetch!(opts, :create_schema)

    if create_schema? and prefix not in [nil, false, "", @default_prefix] do
      execute("CREATE SCHEMA IF NOT EXISTS #{Util.quote_name(prefix)}")
    end
  end

  defp with_defaults(opts) do
    prefix = Keyword.get(opts, :prefix, @default_prefix)

    opts
    |> Keyword.put_new(:prefix, prefix)
    |> Keyword.put_new(:create_schema, prefix not in [nil, false, "", @default_prefix])
  end

  defp versions_result(specs, fun) do
    result = Map.new(specs, fn spec -> {spec.key, fun.(spec)} end)

    if length(specs) == 1 do
      [{_key, version}] = Map.to_list(result)
      version
    else
      result
    end
  end

  defp normalize_specs(opts) do
    selector =
      cond do
        Keyword.has_key?(opts, :adapter) -> Keyword.fetch!(opts, :adapter)
        Keyword.has_key?(opts, :adapters) -> Keyword.fetch!(opts, :adapters)
        true -> [:checkpoint]
      end

    selector
    |> normalize_selector()
    |> Enum.map(&normalize_spec(&1, opts))
    |> Enum.map(&Map.put(&1, :prefix, Keyword.get(opts, :prefix, @default_prefix)))
  end

  defp normalize_selector(:all), do: @adapter_order
  defp normalize_selector(adapter) when is_atom(adapter), do: [adapter]
  defp normalize_selector(adapters) when is_list(adapters), do: adapters

  defp normalize_spec({adapter, adapter_opts}, opts)
       when is_atom(adapter) and is_list(adapter_opts) do
    normalize_spec(adapter, Keyword.merge(opts, adapter_opts))
  end

  defp normalize_spec(:checkpoint = key, opts) do
    adapter_opts = [
      checkpoints_table: Keyword.get(opts, :checkpoints_table, "beam_weaver_checkpoints"),
      writes_table: Keyword.get(opts, :writes_table, "beam_weaver_checkpoint_writes")
    ]

    spec(key, Keyword.fetch!(adapter_opts, :checkpoints_table), adapter_opts)
  end

  defp normalize_spec(:memory = key, opts) do
    adapter_opts = [table: Keyword.get(opts, :table, "beam_weaver_memory_items")]
    spec(key, Keyword.fetch!(adapter_opts, :table), adapter_opts)
  end

  defp normalize_spec(:cache = key, opts) do
    adapter_opts = [table: Keyword.get(opts, :table, "beam_weaver_cache_entries")]
    spec(key, Keyword.fetch!(adapter_opts, :table), adapter_opts)
  end

  defp normalize_spec(:vector_store = key, opts) do
    adapter_opts = [
      table: Keyword.get(opts, :table, "beam_weaver_vectors"),
      dimensions: Keyword.get(opts, :dimensions, 1_536),
      distance: Util.normalize_distance(Keyword.get(opts, :distance, :cosine)),
      index: Keyword.get(opts, :index, :ivfflat),
      index_opts: Keyword.get(opts, :index_opts, []),
      create_extension?: Keyword.get(opts, :create_extension?, true)
    ]

    spec(key, Keyword.fetch!(adapter_opts, :table), adapter_opts)
  end

  defp normalize_spec(:record_manager = key, opts) do
    adapter_opts = [table: Keyword.get(opts, :table, "beam_weaver_indexing_records")]
    spec(key, Keyword.fetch!(adapter_opts, :table), adapter_opts)
  end

  defp normalize_spec(adapter, _opts) do
    raise ArgumentError, "unknown BeamWeaver migration adapter: #{inspect(adapter)}"
  end

  defp spec(key, primary_table, adapter_opts) do
    %{
      key: key,
      adapter_spec: {key, adapter_opts},
      primary_table: to_string(primary_table),
      opts: Map.new(adapter_opts)
    }
  end
end
