defmodule BeamWeaver.Stream.SubgraphRun do
  @moduledoc """
  Native subgraph stream summary.

  BeamWeaver keeps subgraph stream information in typed envelopes. This struct
  is a read-side projection over those envelopes, not a live stream handle.
  """

  defstruct path: [],
            graph: nil,
            graph_name: nil,
            trigger_call_id: nil,
            status: :completed,
            error: nil,
            events: [],
            values: [],
            updates: [],
            tasks: [],
            subgraphs: []

  @type t :: %__MODULE__{
          path: [term()],
          graph: String.t() | nil,
          graph_name: String.t() | nil,
          trigger_call_id: String.t() | nil,
          status: :completed | :failed | :interrupted,
          error: String.t() | nil,
          events: [term()],
          values: [term()],
          updates: [term()],
          tasks: [term()],
          subgraphs: [t()]
        }
end

defmodule BeamWeaver.Stream.Subgraphs do
  @moduledoc """
  Projects typed graph stream envelopes into subgraph run summaries.

  Python LangGraph exposes `SubgraphRunStream` handles backed by child muxes.
  BeamWeaver exposes the same user-visible information as immutable summaries
  grouped by namespace, which fits the BEAM stream/event model and keeps graph
  execution internals private.
  """

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Stream.Envelope
  alias BeamWeaver.Stream.Events
  alias BeamWeaver.Stream.Namespace
  alias BeamWeaver.Stream.SubgraphRun

  @type status :: :completed | :failed | :interrupted

  @spec from_events(Enumerable.t(), keyword() | map()) :: [SubgraphRun.t()]
  def from_events(events, opts \\ []) do
    opts = if is_map(opts), do: Map.to_list(opts), else: opts
    scope = Namespace.normalize(Keyword.get(opts, :scope, []), stringify: true)
    events = Enum.to_list(events)

    events
    |> direct_child_paths(scope)
    |> Enum.map(&build_run(&1, events))
  end

  @spec flatten([SubgraphRun.t()]) :: [SubgraphRun.t()]
  def flatten(runs) when is_list(runs) do
    Enum.flat_map(runs, fn %SubgraphRun{subgraphs: subgraphs} = run ->
      [run | flatten(subgraphs)]
    end)
  end

  defp direct_child_paths(events, scope) do
    scope_length = length(scope)

    events
    |> Enum.map(&Namespace.normalize(Map.get(&1, :namespace, []), stringify: true))
    |> Enum.filter(&(length(&1) > scope_length and Enum.take(&1, scope_length) == scope))
    |> Enum.map(&Enum.take(&1, scope_length + 1))
    |> Enum.uniq()
  end

  defp build_run(path, events) do
    subtree_events = Enum.filter(events, &under_path?(&1, path))

    own_events =
      Enum.filter(subtree_events, &(Namespace.normalize(&1.namespace, stringify: true) == path))

    {status, error} = terminal_status(subtree_events)

    %SubgraphRun{
      path: path,
      graph: graph_name(own_events, subtree_events),
      graph_name: path_graph_name(path),
      trigger_call_id: trigger_call_id(path, events),
      status: status,
      error: error,
      events: subtree_events,
      values: values(own_events),
      updates: updates(own_events),
      tasks: tasks(own_events),
      subgraphs: from_events(events, scope: path)
    }
  end

  defp under_path?(%Envelope{namespace: namespace}, path) do
    namespace = Namespace.normalize(namespace, stringify: true)
    Enum.take(namespace, length(path)) == path
  end

  defp terminal_status(events) do
    case Enum.find(events, &match?(%Envelope{event: %Events.Error{}}, &1)) do
      %Envelope{event: %Events.Error{error: error}} ->
        if interrupted_error?(error),
          do: {:interrupted, error_message(error)},
          else: {:failed, error_message(error)}

      nil ->
        {:completed, nil}
    end
  end

  defp interrupted_error?(%Error{type: type}) when type in [:graph_interrupt, :interrupted],
    do: true

  defp interrupted_error?(%{type: type}) when type in [:graph_interrupt, :interrupted],
    do: true

  defp interrupted_error?(_error), do: false

  defp error_message(%Error{message: message}), do: message
  defp error_message(%{message: message}) when is_binary(message), do: message
  defp error_message(error) when is_binary(error), do: error
  defp error_message(error), do: inspect(error)

  defp graph_name([%Envelope{graph: graph} | _rest], _subtree), do: graph
  defp graph_name([], [%Envelope{graph: graph} | _rest]), do: graph
  defp graph_name([], []), do: nil

  defp path_graph_name([]), do: nil

  defp path_graph_name(path) do
    path
    |> List.last()
    |> to_string()
    |> String.split(":", parts: 2)
    |> hd()
  end

  defp trigger_call_id(path, events) do
    path_segment_id(path) || parent_task_id(path, events)
  end

  defp path_segment_id([]), do: nil

  defp path_segment_id(path) do
    case path |> List.last() |> to_string() |> String.split(":", parts: 2) do
      [_name, id] -> id
      _other -> nil
    end
  end

  defp parent_task_id([], _events), do: nil

  defp parent_task_id(path, events) do
    {parent_path, [node]} = Enum.split(path, length(path) - 1)
    node = path_graph_name([node])

    Enum.find_value(events, fn
      %Envelope{
        namespace: namespace,
        event: %Events.Task{kind: :start, node: event_node, task_id: task_id}
      } ->
        if Namespace.normalize(namespace, stringify: true) == parent_path and
             to_string(event_node) == node,
           do: task_id,
           else: nil

      _other ->
        nil
    end)
  end

  defp values(events) do
    Enum.flat_map(events, fn
      %Envelope{event: %Events.GraphValue{value: value}} -> [value]
      _other -> []
    end)
  end

  defp updates(events) do
    Enum.flat_map(events, fn
      %Envelope{event: %Events.GraphUpdate{update: update}} -> [update]
      _other -> []
    end)
  end

  defp tasks(events) do
    Enum.flat_map(events, fn
      %Envelope{event: %Events.Task{} = event} -> [event]
      _other -> []
    end)
  end
end
