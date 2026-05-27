defmodule BeamWeaver.Runtime.AgentSupervisor do
  @moduledoc false

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      {Task.Supervisor, name: BeamWeaver.Runtime.TaskSupervisor},
      {DynamicSupervisor, name: BeamWeaver.Runtime.Agent.DynamicSupervisor, strategy: :one_for_one}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
