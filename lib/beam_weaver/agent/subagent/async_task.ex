defmodule BeamWeaver.Agent.Subagent.AsyncTask do
  @moduledoc false

  alias BeamWeaver.MapAccess

  @fields [
    :id,
    :task_id,
    :subagent_name,
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

  defstruct (@fields -- [:remote, :updates]) ++ [remote: %{}, updates: []]

  @type t :: %__MODULE__{}

  def new(%__MODULE__{} = task), do: task
  def new(attrs) when is_map(attrs), do: struct(__MODULE__, MapAccess.normalize_keys(attrs, @fields))
end
