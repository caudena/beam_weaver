defmodule BeamWeaver.Checkpoint.PendingWrite do
  @moduledoc """
  Rich checkpoint pending-write record.

  Checkpoint adapters still expose LangGraph-compatible `{task_id, channel,
  value}` tuples through `:pending_writes`. This struct carries the metadata the
  graph execution runtime needs for deterministic replay, namespaces, and future
  channel-specific reconstruction without breaking that tuple surface.
  """

  defstruct [
    :thread_id,
    :checkpoint_ns,
    :checkpoint_id,
    :task_id,
    :index,
    :channel,
    :value,
    path: ""
  ]

  @type t :: %__MODULE__{
          thread_id: String.t(),
          checkpoint_ns: String.t(),
          checkpoint_id: String.t(),
          task_id: String.t(),
          index: non_neg_integer(),
          channel: String.t(),
          value: term(),
          path: String.t()
        }

  @spec tuple(t()) :: {String.t(), String.t(), term()}
  def tuple(%__MODULE__{} = write), do: {write.task_id, write.channel, write.value}

  @spec path_tuple(t()) :: {String.t(), String.t(), String.t()}
  def path_tuple(%__MODULE__{} = write), do: {write.task_id, write.channel, write.path || ""}
end
