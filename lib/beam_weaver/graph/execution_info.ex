defmodule BeamWeaver.Graph.ExecutionInfo do
  @moduledoc """
  Read-only execution metadata for graph node/task work.
  """

  defstruct checkpoint_id: "",
            checkpoint_ns: "",
            task_id: "",
            thread_id: nil,
            run_id: nil,
            node_attempt: 1,
            node_first_attempt_time: nil

  @type t :: %__MODULE__{
          checkpoint_id: String.t(),
          checkpoint_ns: String.t(),
          task_id: String.t(),
          thread_id: String.t() | nil,
          run_id: String.t() | nil,
          node_attempt: pos_integer(),
          node_first_attempt_time: number() | nil
        }

  @spec patch(t(), keyword() | map()) :: t()
  def patch(%__MODULE__{} = info, overrides) when is_list(overrides),
    do: patch(info, Map.new(overrides))

  def patch(%__MODULE__{} = info, overrides) when is_map(overrides) do
    struct(info, normalize_keys(overrides))
  end

  defp normalize_keys(map) do
    Map.new(map, fn {key, value} ->
      key =
        if is_binary(key),
          do: String.to_existing_atom(key),
          else: key

      {key, value}
    end)
  rescue
    ArgumentError -> %{}
  end
end
