defmodule BeamWeaver.Checkpoint.Batch do
  @moduledoc false

  alias BeamWeaver.Core.Error

  @max_entries 1_000
  @max_writes 10_000
  @max_bytes 64 * 1024 * 1024

  @spec validate([map()]) :: :ok | {:error, Error.t()}
  def validate(entries) when is_list(entries) do
    with :ok <- within(length(entries), @max_entries, :entries),
         {:ok, writes, bytes} <- totals(entries),
         :ok <- within(writes, @max_writes, :writes),
         :ok <- within(bytes, @max_bytes, :bytes),
         :ok <- unique_identities(entries) do
      :ok
    end
  rescue
    error -> invalid("checkpoint batch cannot be measured", %{reason: Exception.message(error)})
  end

  def validate(_entries), do: invalid("checkpoint batch must be a list")

  @spec entry(map()) ::
          {:ok, map(), map(), map(), map(), list(), keyword()} | {:error, Error.t()}
  def entry(%{} = entry) do
    config = Map.get(entry, :config)
    checkpoint = Map.get(entry, :checkpoint)
    metadata = Map.get(entry, :metadata, %{})
    versions = Map.get(entry, :versions, %{})
    writes = Map.get(entry, :writes, [])
    write_opts = Map.get(entry, :write_opts, [])

    checkpoint_id = checkpoint && (Map.get(checkpoint, :id) || Map.get(checkpoint, "id"))

    if is_map(config) and is_map(checkpoint) and is_binary(checkpoint_id) and checkpoint_id != "" and
         is_map(metadata) and is_map(versions) and
         is_list(writes) and is_list(write_opts) do
      {:ok, config, checkpoint, metadata, versions, writes, write_opts}
    else
      invalid("checkpoint batch entry requires valid fields and an explicit checkpoint id")
    end
  end

  def entry(_entry), do: invalid("checkpoint batch entries must be maps")

  def fork_entries(lineage, target_thread_id) when is_binary(target_thread_id) do
    Enum.map(lineage, fn tuple ->
      configurable = tuple.config["configurable"]
      parent_id = tuple.parent_config && tuple.parent_config["configurable"]["checkpoint_id"]

      %{
        config: %{
          "configurable" => %{
            "thread_id" => target_thread_id,
            "checkpoint_ns" => configurable["checkpoint_ns"],
            "checkpoint_id" => parent_id
          }
        },
        checkpoint: tuple.checkpoint,
        metadata: tuple.metadata,
        versions: tuple.checkpoint["channel_versions"],
        writes: Map.get(tuple, :pending_write_records, [])
      }
    end)
  end

  defp totals(entries) do
    Enum.reduce_while(entries, {:ok, 0, 0}, fn entry, {:ok, writes, bytes} ->
      case entry(entry) do
        {:ok, _config, _checkpoint, _metadata, _versions, entry_writes, _opts} ->
          {:cont, {:ok, writes + length(entry_writes), bytes + :erlang.external_size(entry)}}

        {:error, %Error{}} = error ->
          {:halt, error}
      end
    end)
  end

  defp unique_identities(entries) do
    identities =
      Enum.map(entries, fn entry ->
        {:ok, config, checkpoint, _metadata, _versions, _writes, _opts} = entry(entry)
        configurable = BeamWeaver.Checkpoint.configurable(config)

        {
          configurable["thread_id"],
          Map.get(configurable, "checkpoint_ns", ""),
          Map.get(checkpoint, :id) || Map.get(checkpoint, "id")
        }
      end)

    if length(identities) == length(Enum.uniq(identities)),
      do: :ok,
      else: invalid("checkpoint batch contains duplicate identities")
  end

  defp within(value, maximum, _field) when value <= maximum, do: :ok

  defp within(value, maximum, field) do
    invalid("checkpoint batch exceeds its #{field} bound", %{
      field: field,
      actual: value,
      maximum: maximum
    })
  end

  defp invalid(message, details \\ %{}),
    do: {:error, Error.new(:invalid_checkpoint_batch, message, details)}
end
