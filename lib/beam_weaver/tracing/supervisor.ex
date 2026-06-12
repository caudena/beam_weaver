defmodule BeamWeaver.Tracing.Supervisor do
  @moduledoc false

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    weavescope_opts = BeamWeaver.Config.group(:weave_scope, [])

    children = [
      BeamWeaver.Tracing.Store,
      {BeamWeaver.Tracing.Exporters.WeaveScope.Queue, weavescope_opts}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
