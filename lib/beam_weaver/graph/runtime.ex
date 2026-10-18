defmodule BeamWeaver.Graph.Runtime do
  @moduledoc ~S"""
  Per-node execution context, supplied as the second argument to two-arity nodes.

  Carries trusted caller context, run configuration, store/checkpointer handles,
  execution metadata and a stream writer. Read attempt/step identity from
  `execution`; do not persist process handles as ordinary checkpoint state.

  Message/UI helpers emit events and return data that a node can also place in
  its state update. Emission alone does not persist that data. See
  [Streaming](streaming.md) and [State](graph_state.md).
  """

  alias BeamWeaver.Graph.ExecutionInfo
  alias BeamWeaver.MapAccess
  alias BeamWeaver.Stream.Events

  @fields [
    :context,
    :store,
    :checkpointer,
    :cache,
    :model_opts,
    :config,
    :graph_name,
    :node,
    :step,
    :scratchpad,
    :stream_sink,
    :stream_writer,
    :stream_modes,
    :run_id,
    :recursion_limit,
    :task_id,
    :namespace,
    :previous_state,
    :checkpoint,
    :execution,
    :server_info
  ]

  defstruct @fields

  @type t :: %__MODULE__{
          context: term(),
          store: struct() | nil,
          checkpointer: struct() | nil,
          cache: struct() | nil,
          model_opts: keyword(),
          config: map(),
          graph_name: String.t(),
          node: String.t(),
          step: non_neg_integer(),
          scratchpad: term(),
          stream_sink: BeamWeaver.Stream.Sink.t() | nil,
          stream_writer: (term() -> :ok),
          stream_modes: MapSet.t(atom()) | nil,
          run_id: String.t(),
          recursion_limit: non_neg_integer() | nil,
          task_id: String.t() | nil,
          namespace: [term()],
          previous_state: map() | nil,
          checkpoint: map() | nil,
          execution: map() | nil,
          server_info: term()
        }

  @doc """
  Returns a runtime copy with explicit field overrides.
  """
  @spec override(t(), keyword() | map()) :: t()
  def override(%__MODULE__{} = runtime, overrides) when is_list(overrides),
    do: override(runtime, Map.new(overrides))

  def override(%__MODULE__{} = runtime, overrides) when is_map(overrides) do
    struct(runtime, normalize_field_overrides(overrides))
  end

  @doc """
  Merges runtime values, preserving the left value when the right side is nil.
  """
  @spec merge(t(), t() | keyword() | map()) :: t()
  def merge(%__MODULE__{} = runtime, %__MODULE__{} = other),
    do: merge(runtime, Map.from_struct(other))

  def merge(%__MODULE__{} = runtime, overrides) when is_list(overrides),
    do: merge(runtime, Map.new(overrides))

  def merge(%__MODULE__{} = runtime, overrides) when is_map(overrides) do
    overrides =
      overrides
      |> normalize_field_overrides()
      |> Map.reject(fn {_key, value} -> is_nil(value) end)

    struct(runtime, overrides)
  end

  @doc """
  Emits a message stream event from inside a graph node.

  The returned message can be included in the node update, usually under the
  `:messages` key backed by `BeamWeaver.Graph.Messages.channel/1`.
  """
  @spec push_message(t(), BeamWeaver.Core.Message.t(), keyword()) ::
          {:ok, BeamWeaver.Core.Message.t()} | {:error, BeamWeaver.Core.Error.t()}
  def push_message(%__MODULE__{stream_writer: writer} = runtime, message, opts \\ []) do
    case BeamWeaver.Core.Message.validate(message) do
      :ok ->
        if is_nil(message.id) do
          {:error,
           BeamWeaver.Core.Error.new(:invalid_message, "message ID is required", %{
             graph: runtime.graph_name,
             node: runtime.node
           })}
        else
          writer.(%Events.Message{
            message: message,
            metadata: Keyword.get(opts, :metadata, %{})
          })

          {:ok, message}
        end

      {:error, error} ->
        {:error, error}
    end
  end

  @doc "Emits a UI message stream event from inside a graph node."
  @spec push_ui_message(t(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, BeamWeaver.Core.Error.t()}
  def push_ui_message(%__MODULE__{} = runtime, name, props, opts \\ []) do
    BeamWeaver.Graph.UI.push_ui_message(runtime, name, props, opts)
  end

  @doc "Emits a UI deletion stream event from inside a graph node."
  @spec delete_ui_message(t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, BeamWeaver.Core.Error.t()}
  def delete_ui_message(%__MODULE__{} = runtime, id, opts \\ []) do
    BeamWeaver.Graph.UI.delete_ui_message(runtime, id, opts)
  end

  @doc """
  Ensures runtime execution info exists, hydrating it from graph config/task data.

  If `runtime.execution` is already populated, the runtime is returned
  unchanged; otherwise this builds an `%ExecutionInfo{}` with the checkpoint id
  and namespace, task id, thread id and run id found in `config` and `task`.
  """
  @spec ensure_execution_info(t(), map(), map() | struct()) :: t()
  def ensure_execution_info(%__MODULE__{execution: %ExecutionInfo{}} = runtime, _config, _task),
    do: runtime

  def ensure_execution_info(%__MODULE__{} = runtime, config, task) when is_map(config) do
    configurable = MapAccess.get(config, :configurable, %{})

    execution = %ExecutionInfo{
      checkpoint_id: MapAccess.get(configurable, :checkpoint_id, ""),
      checkpoint_ns: MapAccess.get(configurable, :checkpoint_ns, ""),
      task_id: MapAccess.get(configurable, :task_id, task_id(task)),
      thread_id: MapAccess.get(configurable, :thread_id),
      run_id: maybe_to_string(MapAccess.get(config, :run_id))
    }

    %{runtime | execution: execution}
  end

  defp task_id(%{id: id}) when not is_nil(id), do: to_string(id)
  defp task_id(%{"id" => id}) when not is_nil(id), do: to_string(id)
  defp task_id(_task), do: ""

  defp maybe_to_string(nil), do: nil
  defp maybe_to_string(value), do: to_string(value)

  defp normalize_field_overrides(overrides),
    do: for({key, value} <- overrides, field = field_atom(key), into: %{}, do: {field, value})

  defp field_atom(key) when is_atom(key) do
    if key in @fields, do: key
  end

  defp field_atom(key) when is_binary(key) do
    Enum.find(@fields, &(Atom.to_string(&1) == key))
  end

  defp field_atom(_key), do: nil
end
