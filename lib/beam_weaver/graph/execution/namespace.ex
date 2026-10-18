defmodule BeamWeaver.Graph.Execution.Namespace do
  @moduledoc false

  @separator "/"
  @task_separator ":"

  @type t :: [String.t()]

  @spec normalize(t() | String.t() | atom() | nil) :: t()
  def normalize(nil), do: []
  def normalize([]), do: []

  def normalize(namespace) when is_binary(namespace), do: String.split(namespace, @separator, trim: true)

  def normalize(namespace) when is_atom(namespace), do: [to_string(namespace)]
  def normalize(namespace) when is_list(namespace), do: Enum.map(namespace, &to_string/1)

  @spec child(t() | String.t() | nil, atom() | String.t(), String.t() | nil) :: t()
  def child(namespace, node, nil), do: normalize(namespace) ++ [to_string(node)]

  def child(namespace, node, task_id),
    do: normalize(namespace) ++ [to_string(node) <> @task_separator <> task_id]

  @spec recast(t() | String.t() | atom() | nil) :: String.t()
  def recast(namespace) do
    Enum.join(
      for(segment <- normalize(namespace), not numeric_segment?(segment), do: strip_task_id(segment)),
      @separator
    )
  end

  @spec serialize(t() | String.t() | atom() | nil) :: String.t()
  def serialize(namespace) do
    namespace
    |> normalize()
    |> Enum.join(@separator)
  end

  defp strip_task_id(segment) do
    segment
    |> String.split(@task_separator, parts: 2)
    |> List.first()
  end

  defp numeric_segment?(segment), do: String.match?(segment, ~r/^\d+$/)

  @doc false
  # Recasts the namespace keys of a `checkpoint_map` to the current separator.
  def recast_checkpoint_map(map) when is_map(map),
    do: Map.new(map, fn {namespace, checkpoint_id} -> {recast(namespace), checkpoint_id} end)

  def recast_checkpoint_map(_other), do: %{}
end
