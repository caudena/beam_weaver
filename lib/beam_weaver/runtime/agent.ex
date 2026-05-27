defmodule BeamWeaver.Runtime.Agent do
  @moduledoc """
  Public API for supervised BeamWeaver agent runtime processes.
  """

  alias BeamWeaver.Runtime.Agent.Server
  alias BeamWeaver.Runtime.Agent.Work

  @type server :: GenServer.server()

  @doc """
  Starts an agent linked to the current process.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    Server.start_link(opts)
  end

  @doc false
  def child_spec(opts) do
    Server.child_spec(opts)
  end

  @doc """
  Starts an agent under BeamWeaver's runtime supervision tree.
  """
  @spec start_child(keyword()) :: DynamicSupervisor.on_start_child()
  def start_child(opts \\ []) do
    DynamicSupervisor.start_child(BeamWeaver.Runtime.Agent.DynamicSupervisor, {Server, opts})
  end

  @doc """
  Subscribes the current process to runtime events from `agent`.
  """
  @spec subscribe(server()) :: :ok
  def subscribe(agent), do: subscribe(agent, self())

  @doc """
  Subscribes `subscriber` to runtime events from `agent`.
  """
  @spec subscribe(server(), pid()) :: :ok
  def subscribe(agent, subscriber) do
    GenServer.call(agent, {:subscribe, subscriber})
  end

  @doc """
  Unsubscribes the current process from runtime events.
  """
  @spec unsubscribe(server()) :: :ok
  def unsubscribe(agent), do: unsubscribe(agent, self())

  @doc """
  Unsubscribes `subscriber` from runtime events.
  """
  @spec unsubscribe(server(), pid()) :: :ok
  def unsubscribe(agent, subscriber) do
    GenServer.call(agent, {:unsubscribe, subscriber})
  end

  @doc """
  Starts model work under the runtime task supervisor.

  The function may accept `(input, emit)`, `(input)`, or no arguments. `emit` sends
  stream chunks through the agent's subscriber event channel.
  """
  @spec start_model_call(server(), term(), function(), keyword()) ::
          {:ok, Work.t()} | {:error, term()}
  def start_model_call(agent, input, fun, opts \\ []) when is_function(fun) do
    GenServer.call(
      agent,
      {:start_work, :model, "model call", input, fun, with_caller_context(opts)}
    )
  end

  @doc """
  Starts tool work under the runtime task supervisor.
  """
  @spec start_tool_call(server(), String.t() | atom(), term(), function(), keyword()) ::
          {:ok, Work.t()} | {:error, term()}
  def start_tool_call(agent, name, input, fun, opts \\ []) when is_function(fun) do
    GenServer.call(
      agent,
      {:start_work, :tool, to_string(name), input, fun, with_caller_context(opts)}
    )
  end

  @doc """
  Cancels active work.
  """
  @spec cancel(server(), Work.id() | Work.t()) :: :ok | {:error, term()}
  def cancel(agent, %Work{id: id}), do: cancel(agent, id)

  def cancel(agent, work_id) do
    GenServer.call(agent, {:cancel, work_id})
  end

  @doc """
  Returns agent runtime status.
  """
  @spec status(server()) :: map()
  def status(agent) do
    GenServer.call(agent, :status)
  end

  defp with_caller_context(opts) do
    Keyword.put_new(opts, :parent_context, BeamWeaver.Tracing.capture_context())
  end
end
