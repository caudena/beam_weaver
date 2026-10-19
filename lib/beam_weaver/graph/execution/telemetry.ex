defmodule BeamWeaver.Graph.Execution.Telemetry do
  @moduledoc false

  @spec execute(atom(), map(), map()) :: :ok
  def execute(event, measurements, metadata) do
    if Code.ensure_loaded?(:telemetry) do
      :telemetry.execute([:beam_weaver, :graph, event], measurements, metadata)
    end

    :ok
  end

  # Emits the first event of a span (`:start`, `:node_start`) and returns its
  # start time for `stop/3`.
  @spec start(atom(), map()) :: integer()
  def start(event, metadata) do
    started_at = System.monotonic_time()
    execute(event, %{system_time: System.system_time(), monotonic_time: started_at}, metadata)
    started_at
  end

  # Ends a span begun at `started_at`; `duration` is in native time units.
  @spec stop(atom(), integer(), map()) :: :ok
  def stop(event, started_at, metadata) do
    stopped_at = System.monotonic_time()

    execute(
      event,
      %{system_time: System.system_time(), monotonic_time: stopped_at, duration: stopped_at - started_at},
      metadata
    )
  end
end
