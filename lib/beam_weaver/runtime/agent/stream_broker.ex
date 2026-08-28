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

  @spec broadcast_progress(%{pid() => reference()}, String.t(), term(), non_neg_integer()) ::
          %{pid() => reference()}
  def broadcast_progress(subscribers, agent_id, event, queue_limit) do
    Enum.reduce(subscribers, subscribers, fn {pid, monitor}, acc ->
      case Process.info(pid, :message_queue_len) do
        {:message_queue_len, length} when length < queue_limit ->
          send(pid, {:beam_weaver_agent, agent_id, event})
          acc

        {:message_queue_len, _full} ->
          acc

        nil ->
          Process.demonitor(monitor, [:flush])
          Map.delete(acc, pid)
      end
    end)
  end

  @spec broadcast_terminal(%{pid() => reference()}, String.t(), term()) ::
          %{pid() => reference()}
  def broadcast_terminal(subscribers, agent_id, event) do
    Enum.reduce(subscribers, subscribers, fn {pid, monitor}, acc ->
      case Process.info(pid, :message_queue_len) do
        {:message_queue_len, _length} ->
          send(pid, {:beam_weaver_agent, agent_id, event})
          acc

        nil ->
          Process.demonitor(monitor, [:flush])
          Map.delete(acc, pid)
      end
    end)
  end
end
