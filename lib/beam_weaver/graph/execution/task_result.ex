defmodule BeamWeaver.Graph.Execution.TaskResult do
  @moduledoc false

  defstruct [:status, :interrupt, :command, update: %{}, updates: [], sends: [], next: [], events: []]

  @type t :: %__MODULE__{
          status: :ok | :interrupted | :parent_command,
          update: map(),
          updates: [map()],
          sends: list(),
          next: list(),
          interrupt: term(),
          command: term(),
          events: list()
        }

  @spec ok(map(), list()) :: t()
  def ok(normalized, events) do
    %__MODULE__{
      status: :ok,
      update: normalized.update,
      updates: normalized.updates,
      sends: normalized.sends,
      next: normalized.next,
      events: events
    }
  end

  @spec interrupted(term(), list()) :: t()
  def interrupted(interrupt, events), do: %__MODULE__{status: :interrupted, interrupt: interrupt, events: events}

  @spec parent_command(term(), list()) :: t()
  def parent_command(command, events), do: %__MODULE__{status: :parent_command, command: command, events: events}
end
