defmodule BeamWeaver.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    BeamWeaver.Provider.Registry.load_from_config!()

    children = [
      BeamWeaver.Transport.Supervisor,
      BeamWeaver.Tracing.Supervisor,
      BeamWeaver.RateLimiter.Supervisor,
      BeamWeaver.Tools.Shell.Sessions
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: BeamWeaver.Supervisor)
  end
end
