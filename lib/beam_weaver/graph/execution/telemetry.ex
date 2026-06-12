defmodule BeamWeaver.Graph.Execution.Telemetry do
  @moduledoc false

  @spec execute(atom(), map(), map()) :: :ok
  def execute(event, measurements, metadata) do
    if Code.ensure_loaded?(:telemetry) do
      :telemetry.execute([:beam_weaver, :graph, event], measurements, metadata)
    end

    :ok
  end
end
