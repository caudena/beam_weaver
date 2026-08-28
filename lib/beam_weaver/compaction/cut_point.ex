defmodule BeamWeaver.Compaction.CutPoint do
  @moduledoc false

  alias BeamWeaver.Compaction.InputEvent

  @spec split([InputEvent.t()], non_neg_integer(), [String.t()]) ::
          {list(InputEvent.t()), list(InputEvent.t())}
  def split(events, tail_budget, active_ids) do
    protected = protected_ids(events, active_ids)

    {_, budget_ordinal, protected_ordinal, _budget_open} =
      events
      |> Enum.reverse()
      |> Enum.reduce({0, nil, nil, true}, fn event, {tokens, budget_first, protected_first, budget_open} ->
        protected_first =
          if MapSet.member?(protected, event.event_id),
            do: event.lane_event_ordinal,
            else: protected_first

        cost = InputEvent.estimated_tokens(event)

        if budget_open and (tokens + cost <= tail_budget or is_nil(budget_first)) do
          {
            tokens + cost,
            event.lane_event_ordinal,
            protected_first,
            true
          }
        else
          {tokens, budget_first, protected_first, false}
        end
      end)

    first_retained_ordinal =
      [budget_ordinal, protected_ordinal]
      |> Enum.reject(&is_nil/1)
      |> Enum.min(fn -> nil end)
      |> expand_tool_pair(events)
      |> safe_boundary(events)

    case first_retained_ordinal do
      nil -> {events, []}
      ordinal -> Enum.split_while(events, &(&1.lane_event_ordinal < ordinal))
    end
  end

  defp protected_ids(events, active_ids) do
    active = MapSet.new(active_ids)

    events
    |> Enum.filter(& &1.protected)
    |> Enum.map(& &1.event_id)
    |> Enum.concat(last_user_ids(events, 2))
    |> Enum.reduce(active, &MapSet.put(&2, &1))
  end

  defp last_user_ids(events, count) do
    events
    |> Enum.reverse()
    |> Enum.filter(&(&1.role == :user))
    |> Enum.take(count)
    |> Enum.map(& &1.event_id)
  end

  defp safe_boundary(nil, _events), do: nil

  defp safe_boundary(ordinal, events) do
    event = Enum.find(events, &(&1.lane_event_ordinal == ordinal))

    if event && event.role == :tool do
      events
      |> Enum.take_while(&(&1.lane_event_ordinal <= ordinal))
      |> Enum.reverse()
      |> Enum.find(&(&1.role != :tool))
      |> case do
        nil -> ordinal
        boundary -> boundary.lane_event_ordinal
      end
    else
      ordinal
    end
  end

  defp expand_tool_pair(nil, _events), do: nil

  defp expand_tool_pair(ordinal, events) do
    retained_call_ids =
      events
      |> Enum.filter(&(&1.lane_event_ordinal >= ordinal))
      |> Enum.flat_map(&tool_call_ids/1)
      |> MapSet.new()

    events
    |> Enum.filter(fn event ->
      event.lane_event_ordinal >= ordinal or
        Enum.any?(tool_call_ids(event), &MapSet.member?(retained_call_ids, &1))
    end)
    |> List.first()
    |> case do
      nil -> ordinal
      event -> event.lane_event_ordinal
    end
  end

  defp tool_call_ids(%InputEvent{tool: %{} = tool}) do
    direct = [Map.get(tool, :call_id), Map.get(tool, "call_id")]

    nested =
      tool
      |> Map.get(:calls, Map.get(tool, "calls", []))
      |> List.wrap()
      |> Enum.flat_map(fn
        call when is_map(call) -> [Map.get(call, :call_id), Map.get(call, "call_id")]
        _call -> []
      end)

    (direct ++ nested)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp tool_call_ids(_event), do: []
end
