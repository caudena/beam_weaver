defmodule BeamWeaver.Checkpoint.Ecto.Listing do
  @moduledoc false

  import Ecto.Query

  alias BeamWeaver.Checkpoint
  alias BeamWeaver.Checkpoint.Ecto, as: EctoSaver
  alias BeamWeaver.Checkpoint.Ecto.Config
  alias BeamWeaver.Checkpoint.Ecto.Query
  alias BeamWeaver.Checkpoint.Ecto.Rows
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Serialization
  alias BeamWeaver.Serialization.JSON.Encoder

  @checkpoint_fields [
    :thread_id,
    :checkpoint_ns,
    :checkpoint_id,
    :parent_checkpoint_id,
    :checkpoint,
    :metadata,
    :commit_order
  ]
  @write_fields [
    :thread_id,
    :checkpoint_ns,
    :checkpoint_id,
    :task_id,
    :write_index,
    :channel,
    :value,
    :task_path
  ]

  def get_tuple(saver, config) do
    case fetch_tuple(saver, config) do
      {:ok, tuple} -> tuple
      {:error, error} -> raise_read_error!(error)
    end
  end

  def fetch_tuple(saver, config) do
    configurable = Checkpoint.configurable(config)

    case configurable["thread_id"] do
      thread_id when is_binary(thread_id) ->
        query =
          saver
          |> checkpoint_query()
          |> where([checkpoint], checkpoint.thread_id == ^thread_id)
          |> where(
            [checkpoint],
            checkpoint.checkpoint_ns == ^Map.get(configurable, "checkpoint_ns", "")
          )
          |> maybe_equal(:checkpoint_id, configurable["checkpoint_id"])
          |> order_by([checkpoint], desc: checkpoint.commit_order)
          |> limit(1)
          |> with_pending_writes(saver)

        with {:ok, rows} <- Query.all(saver, query), do: {:ok, Rows.tuple_from_rows(saver, rows)}

      _other ->
        {:ok, nil}
    end
  end

  def list(saver, config, opts) do
    case list_result(saver, config, opts) do
      {:ok, tuples} -> tuples
      {:error, error} -> raise_read_error!(error)
    end
  end

  def list_result(saver, config, opts) do
    configurable = if config, do: Checkpoint.configurable(config), else: %{}
    limit = Keyword.get(opts, :limit)

    with {:ok, filter} <- metadata_filter(saver, Keyword.get(opts, :filter)),
         {:ok, before_order} <- before_commit_order(saver, Keyword.get(opts, :before)) do
      query =
        saver
        |> checkpoint_query()
        |> maybe_equal(:thread_id, configurable["thread_id"])
        |> maybe_equal(:checkpoint_ns, configurable["checkpoint_ns"])
        |> maybe_before(before_order)
        |> maybe_filter(filter)
        |> order_by(
          [checkpoint],
          desc: checkpoint.commit_order,
          asc: checkpoint.thread_id,
          asc: checkpoint.checkpoint_ns,
          asc: checkpoint.checkpoint_id
        )
        |> maybe_limit(filter, limit)
        |> with_pending_writes(saver)

      with {:ok, rows} <- Query.all(saver, query),
           do: {:ok, saver |> Rows.tuples_from_rows(rows) |> filter_decoded(saver, filter, limit)}
    end
  end

  # The JSON codec stores metadata as plain JSON that SQL can read. Other
  # codecs, such as the encrypted one, store an opaque payload, so metadata is
  # matched after each row is decoded.
  def queryable_metadata?(saver), do: saver.serialization.codec == BeamWeaver.Serialization.JSON

  # Decoded metadata as the JSON codec stores it.
  defp plain_metadata(saver, metadata) do
    Serialization.dump_value(metadata, serialization: [registry: saver.serialization.registry])
  end

  # A filter is the list of `{json_path, json_value}` leaves of the filter as
  # the JSON codec stores it. SQL compares them with the stored metadata when
  # it can read it; otherwise they are compared after each row is decoded.
  # The note naming a map's atom keys is left out, so a nested map matches
  # whether its keys are atoms or strings.
  defp metadata_filter(_saver, filter) when filter in [nil, []] or filter == %{}, do: {:ok, nil}

  defp metadata_filter(saver, filter) do
    filter = Config.stringify_keys(filter)

    if queryable_metadata?(saver) do
      with {:ok, stored} <- EctoSaver.dump_json_value(saver, filter), do: {:ok, {:sql, filter_leaves(stored)}}
    else
      with {:ok, plain} <- plain_metadata(saver, filter), do: {:ok, {:decoded, filter_leaves(plain)}}
    end
  end

  defp filter_decoded(tuples, saver, {:decoded, leaves}, limit) do
    tuples
    |> Enum.filter(&metadata_matches?(saver, &1.metadata, leaves))
    |> take(limit)
  end

  defp filter_decoded(tuples, _saver, _filter, _limit), do: tuples

  defp metadata_matches?(saver, metadata, leaves) do
    case plain_metadata(saver, metadata) do
      {:ok, plain} -> Enum.all?(leaves, fn {path, value} -> json_at(plain, path) == {:ok, value} end)
      {:error, _error} -> false
    end
  end

  defp json_at(value, []), do: {:ok, value}

  defp json_at(%{} = map, [key | path]) do
    case Map.fetch(map, key) do
      {:ok, value} -> json_at(value, path)
      :error -> :error
    end
  end

  defp json_at(_value, _path), do: :error

  defp take(tuples, limit) when is_integer(limit) and limit >= 0, do: Enum.take(tuples, limit)
  defp take(tuples, _limit), do: tuples

  def latest_checkpoint_id_result(saver, thread_id, namespace) do
    query =
      from(checkpoint in Query.checkpoints(saver),
        where: checkpoint.thread_id == ^thread_id and checkpoint.checkpoint_ns == ^namespace,
        order_by: [desc: checkpoint.commit_order],
        limit: 1,
        select: checkpoint.checkpoint_id
      )

    Query.one(saver, query)
  end

  defp checkpoint_query(saver), do: from(checkpoint in Query.checkpoints(saver))

  defp with_pending_writes(query, saver) do
    selected = select(query, [checkpoint], map(checkpoint, ^@checkpoint_fields))

    from(checkpoint in subquery(selected),
      left_join: write in ^Query.writes(saver),
      on:
        write.thread_id == checkpoint.thread_id and
          write.checkpoint_ns == checkpoint.checkpoint_ns and
          (write.checkpoint_id == checkpoint.checkpoint_id or
             (not is_nil(checkpoint.parent_checkpoint_id) and
                write.checkpoint_id == checkpoint.parent_checkpoint_id)),
      order_by: [
        desc: checkpoint.commit_order,
        asc: write.thread_id,
        asc: write.checkpoint_ns,
        asc: write.checkpoint_id,
        asc: write.task_id,
        asc: write.write_index
      ],
      select: {checkpoint, map(write, ^@write_fields)}
    )
  end

  defp maybe_equal(query, _field, nil), do: query

  defp maybe_equal(query, field, value) do
    where(query, [checkpoint], field(checkpoint, ^field) == ^value)
  end

  defp maybe_before(query, nil), do: query
  defp maybe_before(query, order), do: where(query, [checkpoint], checkpoint.commit_order < ^order)

  defp before_commit_order(_saver, nil), do: {:ok, nil}

  defp before_commit_order(saver, before) do
    configurable = Checkpoint.configurable(before)

    query =
      from(checkpoint in Query.checkpoints(saver),
        where:
          checkpoint.thread_id == ^configurable["thread_id"] and
            checkpoint.checkpoint_ns == ^Map.get(configurable, "checkpoint_ns", "") and
            checkpoint.checkpoint_id == ^configurable["checkpoint_id"],
        select: checkpoint.commit_order
      )

    Query.one(saver, query)
  end

  defp maybe_filter(query, {:sql, leaves}) do
    Enum.reduce(leaves, query, fn {path, value}, query ->
      where(query, [checkpoint], json_extract_path(checkpoint.metadata, ^path) == ^value)
    end)
  end

  defp maybe_filter(query, _filter), do: query

  defp filter_leaves(filter) do
    filter
    |> filter_leaves([])
    |> Enum.map(fn {path, value} -> {Enum.reverse(path), value} end)
  end

  defp filter_leaves(map, path) when map_size(map) == 0 and path != [], do: [{path, %{}}]

  defp filter_leaves(map, path) when is_map(map) do
    atom_keys_tag = Encoder.atom_keys_tag()

    Enum.flat_map(map, fn
      {^atom_keys_tag, _names} -> []
      {key, value} -> filter_leaves(value, [to_string(key) | path])
    end)
  end

  defp filter_leaves(value, path), do: [{path, value}]

  # Rows filtered after decoding are limited after the filter.
  defp maybe_limit(query, {:decoded, _leaves}, _limit), do: query
  defp maybe_limit(query, _filter, limit) when is_integer(limit) and limit >= 0, do: limit(query, ^limit)
  defp maybe_limit(query, _filter, _limit), do: query

  defp raise_read_error!(%Error{} = error), do: raise(RuntimeError, error.message)
end
