defmodule BeamWeaver.Agent.Subagent.AsyncTask do
  @moduledoc false

  alias BeamWeaver.MapAccess

  @fields [
    :id,
    :task_id,
    :subagent_name,
    :agent_name,
    :graph_id,
    :url,
    :thread_id,
    :run_id,
    :status,
    :created_at,
    :last_checked_at,
    :last_updated_at,
    :description,
    :remote,
    :updates,
    :result
  ]

  defstruct id: nil,
            task_id: nil,
            subagent_name: nil,
            agent_name: nil,
            graph_id: nil,
            url: nil,
            thread_id: nil,
            run_id: nil,
            status: nil,
            created_at: nil,
            last_checked_at: nil,
            last_updated_at: nil,
            description: nil,
            remote: %{},
            updates: [],
            result: nil

  @type t :: %__MODULE__{}

  def new(%__MODULE__{} = task), do: task
  def new(opts) when is_list(opts), do: opts |> Map.new() |> new()

  def new(attrs) when is_map(attrs) do
    attrs
    |> MapAccess.normalize_keys(@fields)
    |> then(&struct(__MODULE__, &1))
  end

  def to_map(%__MODULE__{} = task), do: Map.from_struct(task)
  def to_map(task) when is_map(task), do: task
end
