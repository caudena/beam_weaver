defmodule BeamWeaver.Checkpoint.Telemetry do
  @moduledoc false

  alias BeamWeaver.Checkpoint.Normalization
  alias BeamWeaver.Telemetry.AdapterEvent
  alias BeamWeaver.Telemetry.AdapterHelpers

  def emit(saver, operation, measurements, config, result, metadata \\ %{}) do
    configurable = Normalization.configurable(config || %{})

    BeamWeaver.Telemetry.emit(
      [:beam_weaver, :checkpoint, operation],
      measurements,
      %AdapterEvent{
        adapter: AdapterHelpers.adapter_name(saver),
        operation: operation,
        thread_id: configurable["thread_id"],
        checkpoint_ns: Map.get(configurable, "checkpoint_ns", ""),
        checkpoint_id: configurable["checkpoint_id"] || result_checkpoint_id(result),
        result: AdapterHelpers.result_type(result, miss_values: [nil]),
        error: AdapterHelpers.error_type(result),
        metadata: metadata
      }
    )
  end

  defp result_checkpoint_id({:ok, config}), do: get_in(config, ["configurable", "checkpoint_id"])
  defp result_checkpoint_id(%{checkpoint: checkpoint}), do: Map.get(checkpoint, "id")
  defp result_checkpoint_id(_result), do: nil
end
