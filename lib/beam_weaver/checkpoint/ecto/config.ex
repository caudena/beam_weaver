defmodule BeamWeaver.Checkpoint.Ecto.Config do
  @moduledoc false

  alias BeamWeaver.Checkpoint

  def generated_id do
    System.unique_integer([:positive, :monotonic])
    |> Integer.to_string()
    |> String.pad_leading(20, "0")
  end

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

  def put_checkpoint_target_namespace(checkpoint, configurable) do
    case Map.get(configurable, "checkpoint_target_ns") do
      nil -> checkpoint
      target -> Map.put(checkpoint, "checkpoint_target_ns", target)
    end
  end

  def put_target_namespace(config, %{"checkpoint_target_ns" => nil}), do: config

  def put_target_namespace(config, configurable) do
    case Map.get(configurable, "checkpoint_target_ns") do
      nil -> config
      target -> put_in(config, ["configurable", "checkpoint_target_ns"], target)
    end
  end

  def normalize_write({channel, value}), do: {to_string(channel), value}
  def normalize_write({_task_id, channel, value}), do: {to_string(channel), value}

  def before_checkpoint_id(nil), do: nil

  def before_checkpoint_id(config) do
    config
    |> Checkpoint.configurable()
    |> Map.get("checkpoint_id")
  end

  def stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end
end
