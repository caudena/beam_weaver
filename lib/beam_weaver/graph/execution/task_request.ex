defmodule BeamWeaver.Graph.Execution.TaskRequest do
  @moduledoc """
  Internal request for the next graph execution task to prepare.

  This sits between channel scheduling and executable task preparation. Keeping
  the request explicit lets the scheduler carry trigger-channel metadata without
  leaking Python-style config bags into the public graph API.
  """

  import Kernel, except: [send: 2]

  alias BeamWeaver.Graph.Execution
  alias BeamWeaver.Graph.Execution.ChannelState

  defstruct [:node, :update, :kind, :timeout, :error, triggers: []]

  @type t :: %__MODULE__{
          node: String.t(),
          update: term(),
          kind: :pull | :send | :push | :subgraph | :error_handler,
          timeout: timeout() | nil,
          error: term(),
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

  def from_checkpoint(%{"node" => node, "update" => update, "timeout" => timeout}),
    do: send(node, update || %{}, [], timeout: timeout)

  def from_checkpoint(%{node: node, update: update, timeout: timeout}),
    do: send(node, update || %{}, [], timeout: timeout)

  def from_checkpoint(%{"node" => node, "update" => update}),
    do: send(node, update || %{})

  def from_checkpoint(%{node: node, update: update}), do: send(node, update || %{})
  def from_checkpoint(%{"node" => node}), do: pull(node)
  def from_checkpoint(%{node: node}), do: pull(node)
  def from_checkpoint({node, update}), do: send(node, update || %{})
  def from_checkpoint(node), do: pull(node)

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

  def raw_path(%__MODULE__{kind: :send, node: node, update: update, timeout: timeout})
      when not is_nil(timeout),
      do: {node, update, timeout}

  def raw_path(%__MODULE__{kind: :send, node: node, update: update}), do: {node, update}
  def raw_path(%__MODULE__{node: node}), do: node
  def raw_path({node, update}), do: {to_string(node), update}
  def raw_path(node), do: to_string(node)

  @spec task_paths(t() | tuple() | atom() | String.t()) :: [term()]
  def task_paths(%__MODULE__{kind: :error_handler, node: node}), do: [{node, "__error_handler__"}]

  def task_paths(%__MODULE__{kind: :send, node: node, update: update, timeout: timeout})
      when not is_nil(timeout),
      do: [{node, update, timeout}]

  def task_paths(%__MODULE__{kind: :send, node: node, update: update}), do: [{node, update}]
  def task_paths(%__MODULE__{node: node}), do: [node, {node, %{}}]
  def task_paths({node, update}), do: [{to_string(node), update}]
  def task_paths(node), do: [to_string(node), {to_string(node), %{}}]

  @spec update(t() | tuple() | atom() | String.t()) :: term()
  def update(%__MODULE__{update: update}), do: update || %{}
  def update({_node, update}), do: update || %{}
  def update(_node), do: %{}

  @spec checkpoint_record(t() | tuple() | atom() | String.t()) :: map()
  def checkpoint_record(%__MODULE__{kind: :error_handler, node: node}),
    do: %{"node" => node, "kind" => "error_handler"}

  def checkpoint_record(%__MODULE__{kind: :send, node: node, update: update} = request) do
    maybe_put_timeout(%{"node" => node, "update" => update || %{}}, request.timeout)
  end

  def checkpoint_record(%__MODULE__{node: node}), do: %{"node" => node}

  def checkpoint_record({node, update}),
    do: %{"node" => to_string(node), "update" => update || %{}}

  def checkpoint_record(node), do: %{"node" => to_string(node)}

  @spec checkpoint_record(t() | tuple() | atom() | String.t(), map()) :: map()
  def checkpoint_record(%__MODULE__{kind: :error_handler, node: node}, _graph),
    do: %{"node" => node, "kind" => "error_handler"}

  def checkpoint_record(%__MODULE__{kind: :send, node: node, update: update} = request, graph)
      when is_map(update) and not is_struct(update) do
    %{"node" => node, "update" => ChannelState.persisted_update(graph, update)}
    |> maybe_put_timeout(request.timeout)
  end

  def checkpoint_record(%__MODULE__{kind: :send, node: node, update: update} = request, _graph) do
    %{"node" => node, "update" => update}
    |> maybe_put_timeout(request.timeout)
  end

  def checkpoint_record({node, update}, graph) when is_map(update) and not is_struct(update) do
    %{"node" => to_string(node), "update" => ChannelState.persisted_update(graph, update)}
  end

  def checkpoint_record({node, update}, _graph) do
    %{"node" => to_string(node), "update" => update}
  end

  def checkpoint_record(ready, _graph), do: checkpoint_record(ready)

  @spec timeout(t() | tuple() | atom() | String.t()) :: timeout() | nil
  def timeout(%__MODULE__{timeout: timeout}), do: timeout
  def timeout(_ready), do: nil

  defp maybe_put_timeout(record, nil), do: record
  defp maybe_put_timeout(record, timeout), do: Map.put(record, "timeout", timeout)
end
