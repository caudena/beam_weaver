defmodule BeamWeaver.Transport.Supervisor do
  @moduledoc false

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    # The supervisor owns the table of the provider stream errors BeamWeaver
    # has warned about, so the table lasts as long as the application.
    BeamWeaver.Provider.StreamFailure.new_table()

    children = [
      {Finch, name: BeamWeaver.Transport.Finch},
      BeamWeaver.Transport.IsolatedPools
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
