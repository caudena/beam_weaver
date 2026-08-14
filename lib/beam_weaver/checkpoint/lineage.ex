defmodule BeamWeaver.Checkpoint.Lineage do
  @moduledoc false

  alias BeamWeaver.Checkpoint
  alias BeamWeaver.Core.Error

  @max_count 10_000
  @max_bytes 64 * 1024 * 1024

  def collect(saver, config, opts) do
    count = Keyword.get(opts, :max_checkpoints, 1_000)
    bytes = Keyword.get(opts, :max_bytes, @max_bytes)

    with :ok <- validate_bounds(count, bytes),
         configurable = Checkpoint.configurable(config),
         true <- is_binary(configurable["checkpoint_id"]),
         {:ok, tuple} when not is_nil(tuple) <- Checkpoint.fetch_tuple(saver, config),
         {:ok, predecessors} <-
           Checkpoint.list_result(saver, owner_config(configurable),
             before: config,
             limit: count - 1
           ) do
      tuples = Map.new([tuple | predecessors], &{checkpoint_id(&1), &1})
      walk(tuple, tuples, [], %{}, count, bytes, 0, length(predecessors) == count - 1)
    else
      false -> error(:invalid_checkpoint_fork, "source checkpoint id is required")
      {:ok, nil} -> error(:checkpoint_not_found, "source checkpoint was not found")
      {:error, _reason} = error -> error
    end
  end

  @spec walk(
          map(),
          map(),
          [map()],
          %{optional(term()) => true},
          non_neg_integer(),
          pos_integer(),
          non_neg_integer(),
          boolean()
        ) :: {:ok, [map()]} | {:error, Error.t()}
  defp walk(_tuple, _tuples, _acc, _seen, 0, _limit, _bytes, _saturated?),
    do: error(:checkpoint_fork_too_large, "checkpoint lineage is too large")

  defp walk(tuple, tuples, acc, seen, remaining, limit, bytes, saturated?) do
    id = checkpoint_id(tuple)
    bytes = bytes + :erlang.external_size(tuple)

    cond do
      Map.has_key?(seen, id) ->
        error(:checkpoint_lineage_cycle, "checkpoint lineage contains a cycle")

      bytes > limit ->
        error(:checkpoint_fork_too_large, "checkpoint lineage is too large")

      is_nil(tuple.parent_config) ->
        {:ok, [tuple | acc]}

      true ->
        parent_id = tuple.parent_config["configurable"]["checkpoint_id"]

        case Map.fetch(tuples, parent_id) do
          {:ok, parent} ->
            walk(
              parent,
              tuples,
              [tuple | acc],
              Map.put(seen, id, true),
              remaining - 1,
              limit,
              bytes,
              saturated?
            )

          :error when saturated? ->
            error(:checkpoint_fork_too_large, "checkpoint lineage is too large")

          :error ->
            error(:checkpoint_lineage_missing, "checkpoint parent is missing")
        end
    end
  end

  defp owner_config(configurable) do
    %{
      "configurable" => Map.take(configurable, ["thread_id", "checkpoint_ns", "checkpoint_target_ns"])
    }
  end

  defp checkpoint_id(tuple), do: tuple.config["configurable"]["checkpoint_id"]

  defp validate_bounds(count, bytes)
       when is_integer(count) and count > 0 and count <= @max_count and is_integer(bytes) and
              bytes > 0 and bytes <= @max_bytes,
       do: :ok

  defp validate_bounds(_count, _bytes),
    do: error(:invalid_checkpoint_fork, "fork bounds are invalid")

  defp error(type, message), do: {:error, Error.new(type, message)}
end
