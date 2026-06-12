defmodule BeamWeaver.Graph.Execution.Namespace do
  @moduledoc """
  BEAM-native checkpoint namespace helpers.

  LangGraph serializes nested graph namespaces into strings that combine graph
  path segments and task IDs. BeamWeaver keeps namespaces as lists internally
  and serializes only at checkpoint boundaries.
  """

  @separator "/"
  @task_separator ":"

  @type t :: [String.t()]

  @spec root() :: t()
  def root, do: []

  @spec normalize(t() | String.t() | atom() | nil) :: t()
  def normalize(nil), do: []
  def normalize([]), do: []

  def normalize(namespace) when is_binary(namespace) do
    namespace
    |> String.split(@separator, trim: true)
    |> Enum.map(&to_string/1)
  end

  def normalize(namespace) when is_atom(namespace), do: [to_string(namespace)]
  def normalize(namespace) when is_list(namespace), do: Enum.map(namespace, &to_string/1)

  @spec child(t() | String.t() | nil, atom() | String.t(), String.t() | nil) :: t()
  def child(namespace, node, nil), do: normalize(namespace) ++ [to_string(node)]

  def child(namespace, node, task_id),
    do: normalize(namespace) ++ [to_string(node) <> @task_separator <> task_id]

  @spec parent(t() | String.t() | nil) :: t()
  def parent(namespace) do
    namespace
    |> normalize()
    |> Enum.reject(&numeric_segment?/1)
    |> Enum.drop(-1)
  end

  @spec recast(t() | String.t() | atom() | nil) :: String.t()
  def recast(namespace) do
    namespace
    |> normalize()
    |> Enum.reject(&numeric_segment?/1)
    |> Enum.map(&strip_task_id/1)
    |> serialize()
  end

  @spec serialize(t() | String.t() | atom() | nil) :: String.t()
  def serialize(namespace) do
    namespace
    |> normalize()
    |> Enum.join(@separator)
  end

  @spec task_segment(atom() | String.t(), String.t()) :: String.t()
  def task_segment(node, task_id), do: to_string(node) <> @task_separator <> task_id

  defp strip_task_id(segment) do
    segment
    |> String.split(@task_separator, parts: 2)
    |> List.first()
  end

  defp numeric_segment?(segment), do: String.match?(segment, ~r/^\d+$/)
end
