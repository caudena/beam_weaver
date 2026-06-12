defmodule BeamWeaver.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    BeamWeaver.Provider.Registry.load_from_config!()

    children = [
      BeamWeaver.ProcessRegistry,
      BeamWeaver.Runtime.AgentSupervisor,
      BeamWeaver.Transport.Supervisor,
      BeamWeaver.Tracing.Supervisor,
      BeamWeaver.RateLimiter.Supervisor
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: BeamWeaver.Supervisor)
  end
end
