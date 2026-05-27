defmodule BeamWeaver.Graph.Execution.TaskResult do
  @moduledoc """
  Normalized result returned by a completed graph execution task.
  """

  alias BeamWeaver.Core.Error

  defstruct [
    :task_id,
    :node,
    :path,
    :step,
    :status,
    :update,
    :updates,
    :sends,
    :next,
    :interrupt,
    :command,
    :error,
    events: []
  ]

  @type t :: %__MODULE__{
          task_id: String.t(),
          node: String.t(),
          path: String.t(),
          step: non_neg_integer(),
          status: :ok | :error | :interrupted | :parent_command,
          update: map(),
          updates: [map()],
          sends: list(),
          next: list(),
          interrupt: term(),
          command: term(),
          error: Error.t() | nil,
          events: list()
        }

  @spec ok(String.t(), String.t(), String.t(), non_neg_integer(), map(), list()) :: t()
  def ok(task_id, node, path, step, normalized, events) do
    %__MODULE__{
      task_id: task_id,
      node: node,
      path: path,
      step: step,
      status: :ok,
      update: normalized.update,
      updates: Map.get(normalized, :updates, update_list(normalized.update)),
      sends: normalized.sends,
      next: normalized.next,
      events: events
    }
  end

  @spec error(String.t(), String.t(), String.t(), non_neg_integer(), Error.t(), list()) :: t()
  def error(task_id, node, path, step, %Error{} = error, events) do
    %__MODULE__{
      task_id: task_id,
      node: node,
      path: path,
      step: step,
      status: :error,
      update: %{},
      updates: [],
      sends: [],
      next: [],
      error: error,
      events: events
    }
  end

  @spec interrupted(String.t(), String.t(), String.t(), non_neg_integer(), term(), list()) :: t()
  def interrupted(task_id, node, path, step, interrupt, events) do
    %__MODULE__{
      task_id: task_id,
      node: node,
      path: path,
      step: step,
      status: :interrupted,
      update: %{},
      updates: [],
      sends: [],
      next: [],
      interrupt: interrupt,
      events: events
    }
  end

  @spec parent_command(String.t(), String.t(), String.t(), non_neg_integer(), term(), list()) ::
          t()
  def parent_command(task_id, node, path, step, command, events) do
    %__MODULE__{
      task_id: task_id,
      node: node,
      path: path,
      step: step,
      status: :parent_command,
      update: %{},
      updates: [],
      sends: [],
      next: [],
      command: command,
      events: events
    }
  end

  defp update_list(update) when update == %{}, do: []
  defp update_list(update) when is_map(update), do: [update]
  defp update_list(_update), do: []
end
