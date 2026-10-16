defmodule BeamWeaver.Tools.Shell.Sessions do
  @moduledoc false

  # Supervises `BeamWeaver.Tools.Shell.Session` processes and, for a run with a
  # thread id, registers each under a stable key so a resumed run finds the
  # same session instead of a dead pid saved in state. Sessions are temporary
  # (never restarted) and carry an idle timeout, so a run that never reaches
  # `after_agent` (a human-review pause, an error, an early jump) does not leak
  # a session forever.

  use Supervisor

  alias BeamWeaver.Tools.Shell.Session

  @registry __MODULE__.Registry
  @supervisor __MODULE__.DynamicSupervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: @registry},
      {DynamicSupervisor, strategy: :one_for_one, name: @supervisor}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Returns a live session registered under `key`, starting one from `start_opts`
  if none is registered or the registered one has stopped.
  """
  @spec fetch_or_start(term(), keyword()) :: {:ok, pid()} | {:error, term()}
  def fetch_or_start(key, start_opts) do
    case fetch(key) do
      {:ok, pid} -> {:ok, pid}
      :error -> start_child(Keyword.put(start_opts, :name, via(key)))
    end
  end

  @doc "Starts an unregistered supervised session (for a run with no thread id)."
  @spec start(keyword()) :: {:ok, pid()} | {:error, term()}
  def start(start_opts), do: start_child(start_opts)

  @doc "Returns the live session registered under `key`, if any."
  @spec fetch(term()) :: {:ok, pid()} | :error
  def fetch(key) do
    case Registry.lookup(@registry, key) do
      [{pid, _value}] -> if Process.alive?(pid), do: {:ok, pid}, else: :error
      [] -> :error
    end
  end

  @doc """
  The registry key for a run's session: stable across a pause and resume on the
  same thread, and distinct per shell tool (state key and name).
  """
  @spec key(term(), atom(), String.t()) :: term()
  def key(thread_id, state_key, tool_name), do: {__MODULE__, thread_id, state_key, tool_name}

  @doc "The thread id in a run config/runtime config, or `nil` when there is none."
  @spec thread_id(map() | nil) :: term() | nil
  def thread_id(config) when is_map(config) do
    configurable = Map.get(config, "configurable") || Map.get(config, :configurable) || %{}

    if is_map(configurable),
      do: Map.get(configurable, "thread_id") || Map.get(configurable, :thread_id),
      else: nil
  end

  def thread_id(_config), do: nil

  defp start_child(start_opts) do
    case DynamicSupervisor.start_child(@supervisor, {Session, start_opts}) do
      {:ok, pid} -> {:ok, pid}
      {:ok, pid, _info} -> {:ok, pid}
      # A concurrent caller won the registration race; use its session.
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, _reason} = error -> error
    end
  end

  defp via(key), do: {:via, Registry, {@registry, key}}
end
