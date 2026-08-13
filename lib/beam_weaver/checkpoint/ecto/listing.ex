defmodule BeamWeaver.Checkpoint.Ecto.Listing do
  @moduledoc false

  import Ecto.Query

  alias BeamWeaver.Checkpoint
  alias BeamWeaver.Checkpoint.Ecto, as: EctoSaver
  alias BeamWeaver.Checkpoint.Ecto.Config
  alias BeamWeaver.Checkpoint.Ecto.Query
  alias BeamWeaver.Checkpoint.Ecto.Rows
  alias BeamWeaver.Core.Error

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
          |> maybe_checkpoint_id(configurable["checkpoint_id"])
          |> order_by([checkpoint], desc: checkpoint.commit_order)
          |> limit(1)
          |> with_pending_writes(saver)

        case Query.all(saver, query) do
          {:ok, rows} -> {:ok, Rows.tuple_from_rows(saver, rows)}
          {:error, _reason} = error -> error
        end

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
    filter = Config.stringify_keys(Keyword.get(opts, :filter, %{}) || %{})

    with {:ok, stored_filter} <- EctoSaver.dump_json_value(saver, filter),
         {:ok, before_order} <- before_commit_order(saver, Keyword.get(opts, :before)) do
      query =
        saver
        |> checkpoint_query()
        |> maybe_equal(:thread_id, configurable["thread_id"])
        |> maybe_equal(:checkpoint_ns, configurable["checkpoint_ns"])
        |> maybe_before(before_order)
        |> maybe_filter(stored_filter)
        |> order_by(
          [checkpoint],
          desc: checkpoint.commit_order,
          asc: checkpoint.thread_id,
          asc: checkpoint.checkpoint_ns,
          asc: checkpoint.checkpoint_id
        )
        |> maybe_limit(Keyword.get(opts, :limit))
        |> with_pending_writes(saver)

      case Query.all(saver, query) do
        {:ok, rows} -> {:ok, Rows.tuples_from_rows(saver, rows)}
        {:error, _reason} = error -> error
      end
    end
  end

  def resolve_checkpoint_id(_saver, _thread_id, _namespace, checkpoint_id)
      when is_binary(checkpoint_id),
      do: {:ok, checkpoint_id}

  def resolve_checkpoint_id(saver, thread_id, namespace, _checkpoint_id) do
    case latest_checkpoint_id(saver, thread_id, namespace) do
      nil -> :error
      checkpoint_id -> {:ok, checkpoint_id}
    end
  end

  def latest_checkpoint_id(saver, thread_id, namespace) do
    case latest_checkpoint_id_result(saver, thread_id, namespace) do
      {:ok, checkpoint_id} -> checkpoint_id
      {:error, error} -> raise_read_error!(error)
    end
  end

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

  defp maybe_checkpoint_id(query, nil), do: query

  defp maybe_checkpoint_id(query, checkpoint_id) do
    where(query, [checkpoint], checkpoint.checkpoint_id == ^checkpoint_id)
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

  defp maybe_filter(query, filter) when filter in [%{}, nil], do: query

  defp maybe_filter(query, filter) do
    filter
    |> filter_leaves()
    |> Enum.reduce(query, fn {path, value}, query ->
      where(query, [checkpoint], json_extract_path(checkpoint.metadata, ^path) == ^value)
    end)
  end

  defp filter_leaves(filter) do
    filter
    |> filter_leaves([])
    |> Enum.map(fn {path, value} -> {Enum.reverse(path), value} end)
  end

  defp filter_leaves(map, path) when map_size(map) == 0 and path != [], do: [{path, %{}}]

  defp filter_leaves(map, path) when is_map(map) do
    Enum.flat_map(map, fn {key, value} -> filter_leaves(value, [to_string(key) | path]) end)
  end

  defp filter_leaves(value, path), do: [{path, value}]

  defp maybe_limit(query, limit) when is_integer(limit) and limit >= 0, do: limit(query, ^limit)
  defp maybe_limit(query, _limit), do: query

  defp raise_read_error!(%Error{} = error), do: raise(RuntimeError, error.message)
  defp raise_read_error!(error), do: raise(RuntimeError, inspect(error))
end
