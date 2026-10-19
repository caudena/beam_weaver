defmodule BeamWeaver.Checkpoint.Ecto.Config do
  @moduledoc false

  def checkpoint_map(configurable, namespace, checkpoint_id) do
    configurable
    |> Map.get("checkpoint_map", %{})
    |> normalize_checkpoint_map()
    |> Map.put(to_string(namespace || ""), checkpoint_id)
  end

  def normalize_checkpoint_map(map) when is_map(map) do
    Map.new(map, fn {namespace, id} -> {to_string(namespace || ""), id} end)
  end

  def normalize_checkpoint_map(_other), do: %{}

  def stored_config(thread_id, namespace, checkpoint_id, checkpoint_map, target_ns) do
    configurable = %{
      "thread_id" => thread_id,
      "checkpoint_ns" => namespace,
      "checkpoint_id" => checkpoint_id,
      "checkpoint_map" => checkpoint_map
    }

    %{"configurable" => BeamWeaver.MapShape.put_present(configurable, "checkpoint_target_ns", target_ns)}
  end

  def normalize_write({channel, value}), do: {to_string(channel), value}
  def normalize_write({_task_id, channel, value}), do: {to_string(channel), value}

  def store_write_value(value) do
    %{"__beam_weaver_checkpoint_write__" => 1, "value" => value}
  end

  def load_write_value(%{"__beam_weaver_checkpoint_write__" => 1, "value" => value}), do: value
  def load_write_value(value), do: value

  def stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end
end
