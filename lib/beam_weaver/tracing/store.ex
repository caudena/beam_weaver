defmodule BeamWeaver.Tracing.Store do
  @moduledoc false

  use Agent

  alias BeamWeaver.Tracing.Run

  def start_link(opts \\ []) do
    Agent.start_link(fn -> %{} end, Keyword.put_new(opts, :name, __MODULE__))
  end

  @spec put(Run.t()) :: :ok
  def put(%Run{} = run) do
    Agent.update(__MODULE__, &Map.put(&1, run.id, run))
  end

  @spec get(Run.id()) :: {:ok, Run.t()} | :error
  def get(run_id) do
    case Agent.get(__MODULE__, &Map.get(&1, run_id)) do
      nil -> :error
      %Run{} = run -> {:ok, run}
    end
  end

  @spec update(Run.id(), (Run.t() -> Run.t())) :: {:ok, Run.t()} | :error
  def update(run_id, updater) when is_function(updater, 1) do
    Agent.get_and_update(__MODULE__, fn runs ->
      case Map.fetch(runs, run_id) do
        {:ok, %Run{} = run} ->
          updated = updater.(run)
          {{:ok, updated}, Map.put(runs, run_id, updated)}

        :error ->
          {:error, runs}
      end
    end)
  end

  @spec list() :: [Run.t()]
  def list do
    Agent.get(__MODULE__, fn runs ->
      runs
      |> Map.values()
      |> Enum.sort_by(&timestamp_key/1)
    end)
  end

  @spec tree(Run.id()) :: {:ok, map()} | :error
  def tree(run_id) do
    runs = Agent.get(__MODULE__, & &1)

    case Map.fetch(runs, run_id) do
      {:ok, run} -> {:ok, build_tree(run, runs)}
      :error -> :error
    end
  end

  @spec reset() :: :ok
  def reset do
    Agent.update(__MODULE__, fn _runs -> %{} end)
  end

  defp build_tree(%Run{} = run, runs) do
    children =
      runs
      |> Map.values()
      |> Enum.filter(&(&1.parent_id == run.id))
      |> Enum.sort_by(&timestamp_key/1)
      |> Enum.map(&build_tree(&1, runs))

    %{run: run, children: children}
  end

  defp timestamp_key(run) do
    DateTime.to_unix(run.started_at, :microsecond)
  end
end
