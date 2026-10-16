defmodule BeamWeaver.Graph.Execution.TaskRequest do
  @moduledoc false

  import Kernel, except: [send: 2]

  alias BeamWeaver.Graph.Execution
  alias BeamWeaver.Graph.Execution.ChannelLookup

  # Every `Send` of a step runs as its own task. `repeat` tells apart the ones
  # that are otherwise the same (node, update and timeout): the first has 0,
  # the next 1, and so on.
  defstruct [:node, :update, :kind, :timeout, :error, repeat: 0, triggers: []]

  @type t :: %__MODULE__{
          node: String.t(),
          update: term(),
          kind: :pull | :send | :push | :subgraph | :error_handler,
          timeout: timeout() | nil,
          error: term(),
          repeat: non_neg_integer(),
          triggers: [String.t()]
        }

  @spec pull(atom() | String.t(), Enumerable.t()) :: t()
  def pull(node, triggers \\ []) do
    %__MODULE__{
      node: to_string(node),
      update: %{},
      kind: :pull,
      triggers: Execution.normalize_channels(triggers)
    }
  end

  @spec send(atom() | String.t(), term(), Enumerable.t(), keyword()) :: t()
  def send(node, update, triggers \\ [], opts \\ []) do
    %__MODULE__{
      node: to_string(node),
      update: update || %{},
      kind: :send,
      timeout: Keyword.get(opts, :timeout),
      repeat: Keyword.get(opts, :repeat) || 0,
      triggers: Execution.normalize_channels(triggers)
    }
  end

  @spec error_handler(atom() | String.t(), term(), Enumerable.t()) :: t()
  def error_handler(node, error, triggers \\ []) do
    %__MODULE__{
      node: to_string(node),
      update: %{},
      kind: :error_handler,
      error: error,
      triggers: Execution.normalize_channels(triggers)
    }
  end

  @spec from_checkpoint(term()) :: t()
  def from_checkpoint(%__MODULE__{} = request), do: request

  def from_checkpoint(%{"node" => node, "update" => update} = record),
    do:
      send(node, restore_update(update, record), [],
        timeout: Map.get(record, "timeout"),
        repeat: Map.get(record, "repeat")
      )

  def from_checkpoint(%{node: node, update: update} = record),
    do: send(node, update || %{}, [], timeout: Map.get(record, :timeout), repeat: Map.get(record, :repeat))

  def from_checkpoint(%{"node" => node}), do: pull(node)
  def from_checkpoint(%{node: node}), do: pull(node)
  def from_checkpoint({node, update}), do: send(node, update || %{})
  def from_checkpoint(node), do: pull(node)

  # A saved record as callers see it in a snapshot. Records saved before map
  # keys kept their types name the update's atom keys in "atom_keys"; the
  # update gets them back and the list is dropped.
  @spec public_record(map()) :: map()
  def public_record(%{"update" => update} = record) do
    record
    |> Map.delete("atom_keys")
    |> Map.put("update", restore_update(update, record))
  end

  def public_record(record), do: record

  @spec name(t() | tuple() | atom() | String.t()) :: String.t()
  def name(%__MODULE__{node: node}), do: node
  def name({node, _update}), do: to_string(node)
  def name(node), do: to_string(node)

  @spec kind(t() | tuple() | atom() | String.t()) :: :pull | :send
  def kind(%__MODULE__{kind: kind}), do: kind
  def kind({_node, _update}), do: :send
  def kind(_node), do: :pull

  @spec error(t() | tuple() | atom() | String.t()) :: term()
  def error(%__MODULE__{error: error}), do: error
  def error(_ready), do: nil

  @spec raw_path(t() | tuple() | atom() | String.t()) :: term()
  def raw_path(%__MODULE__{kind: :error_handler, node: node}), do: {node, "__error_handler__"}
  def raw_path(%__MODULE__{kind: :send} = request), do: send_path(request)
  def raw_path(%__MODULE__{node: node}), do: node
  def raw_path({node, update}), do: {to_string(node), update}
  def raw_path(node), do: to_string(node)

  @spec task_paths(t() | tuple() | atom() | String.t()) :: [term()]
  def task_paths(%__MODULE__{kind: :error_handler, node: node}), do: [{node, "__error_handler__"}]
  def task_paths(%__MODULE__{kind: :send} = request), do: [send_path(request)]
  def task_paths(%__MODULE__{node: node}), do: [node, {node, %{}}]
  def task_paths({node, update}), do: [{to_string(node), update}]
  def task_paths(node), do: [to_string(node), {to_string(node), %{}}]

  # A repeated `Send` adds its count to the path that its task id comes from;
  # the first one keeps the path of a `Send` that isn't repeated.
  defp send_path(%__MODULE__{node: node, update: update, timeout: nil, repeat: 0}), do: {node, update}

  defp send_path(%__MODULE__{node: node, update: update, timeout: timeout, repeat: 0}),
    do: {node, update, timeout}

  defp send_path(%__MODULE__{node: node, update: update, timeout: timeout, repeat: repeat}),
    do: {node, update, timeout, repeat}

  # Requests for the same task. The edges that reach a node in a step run it
  # once, while every `Send` is its own task.
  @spec key(t() | tuple() | atom() | String.t()) :: term()
  def key(%__MODULE__{kind: :error_handler, node: node, error: error}), do: {:error_handler, node, error}
  def key(ready), do: {kind(ready), raw_path(ready)}

  @spec update(t() | tuple() | atom() | String.t()) :: term()
  def update(%__MODULE__{update: update}), do: update || %{}
  def update({_node, update}), do: update || %{}
  def update(_node), do: %{}

  # A task's record in a checkpoint's `next_tasks`.
  @spec checkpoint_record(t() | tuple() | atom() | String.t()) :: map()
  def checkpoint_record(%__MODULE__{kind: :error_handler, node: node}),
    do: %{"node" => node, "kind" => "error_handler"}

  def checkpoint_record(%__MODULE__{kind: :send, node: node, update: update} = request),
    do: send_record(node, update || %{}, request)

  def checkpoint_record(%__MODULE__{node: node}), do: %{"node" => node}
  def checkpoint_record({node, update}), do: send_record(to_string(node), update || %{}, nil)
  def checkpoint_record(node), do: %{"node" => to_string(node)}

  @spec checkpoint_record(t() | tuple() | atom() | String.t(), map()) :: map()
  def checkpoint_record(%__MODULE__{kind: :send, node: node, update: update} = request, graph)
      when is_map(update) and not is_struct(update),
      do: send_record(node, ChannelLookup.persisted_update(graph, update), request)

  def checkpoint_record({node, update}, graph) when is_map(update) and not is_struct(update),
    do: send_record(to_string(node), ChannelLookup.persisted_update(graph, update), nil)

  def checkpoint_record(ready, _graph), do: checkpoint_record(ready)

  defp send_record(node, update, nil), do: %{"node" => node, "update" => update}

  defp send_record(node, update, %__MODULE__{timeout: timeout, repeat: repeat}) do
    %{"node" => node, "update" => update}
    |> maybe_put_timeout(timeout)
    |> maybe_put_repeat(repeat)
  end

  defp restore_update(update, record) when is_map(update) and not is_struct(update),
    do: ChannelLookup.restore_atom_keys(update, Map.get(record, "atom_keys"))

  defp restore_update(update, _record), do: update || %{}

  @spec timeout(t() | tuple() | atom() | String.t()) :: timeout() | nil
  def timeout(%__MODULE__{timeout: timeout}), do: timeout
  def timeout(_ready), do: nil

  defp maybe_put_timeout(record, nil), do: record
  defp maybe_put_timeout(record, timeout), do: Map.put(record, "timeout", timeout)

  defp maybe_put_repeat(record, 0), do: record
  defp maybe_put_repeat(record, repeat), do: Map.put(record, "repeat", repeat)
end
