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

  @spec broadcast(%{pid() => reference()}, String.t(), term(), non_neg_integer()) ::
          %{pid() => reference()}
  def broadcast(subscribers, agent_id, event, queue_limit) do
    Enum.reduce(subscribers, subscribers, fn {pid, monitor}, acc ->
      case Process.info(pid, :message_queue_len) do
        {:message_queue_len, length} when length < queue_limit ->
          send(pid, {:beam_weaver_agent, agent_id, event})
          acc

        _full_or_down ->
          Process.demonitor(monitor, [:flush])
          Map.delete(acc, pid)
      end
    end)
  end
end
