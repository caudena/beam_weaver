defmodule BeamWeaver.Runtime.Agent.StreamBroker do
  @moduledoc false

  @spec subscribe(%{pid() => reference()}, pid()) :: %{pid() => reference()}
  def subscribe(subscribers, pid) when is_pid(pid) do
    Map.put_new_lazy(subscribers, pid, fn -> Process.monitor(pid) end)
  end

  @spec unsubscribe(%{pid() => reference()}, pid()) :: %{pid() => reference()}
  def unsubscribe(subscribers, pid) when is_pid(pid) do
    case Map.pop(subscribers, pid) do
      {nil, subscribers} ->
        subscribers

      {monitor, subscribers} ->
        Process.demonitor(monitor, [:flush])
        subscribers
    end
  end

  @spec remove_down(%{pid() => reference()}, reference()) :: %{pid() => reference()}
  def remove_down(subscribers, monitor) do
    subscribers
    |> Enum.reject(fn {_pid, ref} -> ref == monitor end)
    |> Map.new()
  end

  @spec broadcast(%{pid() => reference()}, String.t(), term()) :: :ok
  def broadcast(subscribers, agent_id, event) do
    Enum.each(subscribers, fn {pid, _monitor} ->
      send(pid, {:beam_weaver_agent, agent_id, event})
    end)
  end
end
