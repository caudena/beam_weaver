defmodule BeamWeaver.Tracing.Supervisor do
  @moduledoc false

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    langsmith_opts = BeamWeaver.Config.group(:langsmith, [])

    children =
      [
        BeamWeaver.Tracing.Store,
        {BeamWeaver.Tracing.Exporters.LangSmith.Queue, langsmith_opts}
      ] ++ telemetry_children(langsmith_opts)

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp telemetry_children(opts) do
    if Keyword.get(opts, :telemetry?, false) do
      [
        {BeamWeaver.Tracing.Exporters.LangSmith.TelemetrySubscriber,
         [queue: BeamWeaver.Tracing.Exporters.LangSmith.Queue]}
      ]
    else
      []
    end
  end
end
