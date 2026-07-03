defmodule BeamWeaver.Agent.Subagent.RunStream do
  @moduledoc """
  Immutable DeepAgents subagent stream summary.

  Python DeepAgents exposes live `RunStream` handles. BeamWeaver keeps
  the same observable metadata as immutable structs produced from stream events:
  the declared subagent name, user-facing tool-call cause, latest output,
  terminal status, nested subagents, and the events observed under the run path.
  """

  defstruct path: [],
            graph_name: nil,
            trigger_call_id: nil,
            task_input: nil,
            status: :started,
            error: nil,
            events: [],
            values: [],
            updates: [],
            subagents: []

  @type status :: :started | :completed | :failed | :interrupted

  @type t :: %__MODULE__{
          path: [String.t()],
          graph_name: String.t() | nil,
          trigger_call_id: String.t() | nil,
          task_input: String.t() | nil,
          status: status(),
          error: String.t() | nil,
          events: [term()],
          values: [term()],
          updates: [term()],
          subagents: [t()]
        }

  @spec name(t()) :: String.t() | nil
  def name(%__MODULE__{graph_name: graph_name}), do: graph_name

  @spec cause(t()) :: map() | nil
  def cause(%__MODULE__{trigger_call_id: nil}), do: nil
  def cause(%__MODULE__{trigger_call_id: ""}), do: nil

  def cause(%__MODULE__{trigger_call_id: tool_call_id}),
    do: %{"type" => "toolCall", "tool_call_id" => tool_call_id}

  @spec output(t()) :: term() | nil
  def output(%__MODULE__{values: []}), do: nil
  def output(%__MODULE__{values: values}), do: List.last(values)
end

defmodule BeamWeaver.Agent.Subagent.AsyncRunStream do
  @moduledoc """
  Async marker variant for DeepAgents subagent stream summaries.

  The BEAM representation is immutable like `RunStream`; the separate
  struct exists so callers can preserve Python's sync/async distinction when a
  producer marks child stream events as async.
  """

  defstruct path: [],
            graph_name: nil,
            trigger_call_id: nil,
            task_input: nil,
            status: :started,
            error: nil,
            events: [],
            values: [],
            updates: [],
            subagents: []
end

defmodule BeamWeaver.Agent.Subagent.StreamTransformer do
  @moduledoc """
  Projects declared DeepAgents subagent executions from graph stream events.

  The transformer mirrors `deepagents._subagent_transformer` without exposing
  LangGraph's live mux internals. It learns the declared subagent type and the
  user-facing tool-call id from parent-scope `tools` task-start events, then
  promotes matching child namespaces such as `tools:<parent_task_id>` into
  typed `RunStream` summaries.
  """

  alias BeamWeaver.Agent.Subagent.AsyncRunStream
  alias BeamWeaver.Agent.Subagent.RunStream
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Stream.Envelope
  alias BeamWeaver.Stream.Events
  alias BeamWeaver.Stream.Namespace

  defstruct scope: [],
            subagent_names: MapSet.new(),
            pending: %{},
            task_paths: %{},
            handles: %{},
            log: []

  @type t :: %__MODULE__{
          scope: [String.t()],
          subagent_names: MapSet.t(String.t()),
          pending: map(),
          task_paths: map(),
          handles: %{optional([String.t()]) => RunStream.t()},
          log: [RunStream.t()]
        }

  @spec new(keyword() | map()) :: t()
  def new(opts \\ []) do
    opts = if is_map(opts), do: Map.to_list(opts), else: opts

    %__MODULE__{
      scope: Namespace.normalize(Keyword.get(opts, :scope, []), stringify: true),
      subagent_names:
        opts
        |> Keyword.get(:subagent_names, [])
        |> normalize_names()
    }
  end

  @spec init(t()) :: map()
  def init(%__MODULE__{} = transformer), do: %{subagents: transformer.log}

  @spec process(t(), term()) :: {:ok, t(), [RunStream.t()]} | {:pass, t()}
  def process(%__MODULE__{} = transformer, event) do
    normalized = normalize_event(event)

    case normalized do
      %{method: "tasks", namespace: namespace, data: data} ->
        transformer
        |> capture_pending(namespace, data)
        |> maybe_start_handle(namespace, data, event)
        |> maybe_finish_handle(namespace, data, event)
        |> emit_result(transformer)

      %{method: method, namespace: namespace, data: data} when method in ["values", "updates"] ->
        transformer
        |> route_data(method, namespace, data, event)
        |> emit_result(transformer)

      %{method: "error", namespace: namespace, data: data} ->
        transformer
        |> mark_namespace_terminal(namespace, :failed, error_message(data), event)
        |> emit_result(transformer)

      _other ->
        {:pass, transformer}
    end
  end

  @spec process_many(t(), Enumerable.t()) :: {:ok, t(), [RunStream.t()]}
  def process_many(%__MODULE__{} = transformer, events) do
    Enum.reduce(events, {:ok, transformer, []}, fn event, {:ok, acc, emitted} ->
      case process(acc, event) do
        {:ok, next, new_handles} -> {:ok, next, emitted ++ new_handles}
        {:pass, next} -> {:ok, next, emitted}
      end
    end)
  end

  @spec finalize(t()) :: t()
  def finalize(%__MODULE__{} = transformer) do
    transformer.handles
    |> Enum.filter(fn {_path, handle} -> handle.status == :started end)
    |> Enum.reduce(transformer, fn {path, _handle}, acc ->
      update_handle(acc, path, &%{&1 | status: :completed})
    end)
  end

  @spec fail(t(), term()) :: t()
  def fail(%__MODULE__{} = transformer, reason) do
    status = if interrupted?(reason), do: :interrupted, else: :failed
    message = if status == :failed, do: error_message(reason), else: nil

    transformer.handles
    |> Enum.filter(fn {_path, handle} -> handle.status == :started end)
    |> Enum.reduce(transformer, fn {path, _handle}, acc ->
      update_handle(acc, path, &%{&1 | status: status, error: message || &1.error})
    end)
  end

  defp emit_result(%__MODULE__{} = next, %__MODULE__{} = previous) do
    new_paths = Map.keys(next.handles) -- Map.keys(previous.handles)
    new_handles = Enum.map(new_paths, &Map.fetch!(next.handles, &1))

    if next == previous and new_handles == [],
      do: {:pass, next},
      else: {:ok, next, new_handles}
  end

  defp capture_pending(%__MODULE__{} = transformer, namespace, data) do
    if parent_scope?(transformer, namespace) and task_start?(data) and task_name(data) == "tools" do
      parent_task_id = data_value(data, :id) || data_value(data, :task_id)
      tool_calls = data_value(data, :input)

      case pending_info(tool_calls) do
        nil ->
          transformer

        info when is_binary(parent_task_id) ->
          key = {namespace, parent_task_id}
          %{transformer | pending: Map.put(transformer.pending, key, info)}

        _info ->
          transformer
      end
    else
      transformer
    end
  end

  defp maybe_start_handle(%__MODULE__{} = transformer, namespace, data, raw_event) do
    with true <- task_start?(data),
         {parent_namespace, parent_task_id} <- parent_task_key(namespace),
         true <- parent_scope?(transformer, parent_namespace),
         info when not is_nil(info) <-
           Map.get(transformer.pending, {parent_namespace, parent_task_id}),
         true <- MapSet.member?(transformer.subagent_names, info.subagent_type),
         false <- Map.has_key?(transformer.handles, namespace) do
      handle = new_handle(namespace, info, raw_event)

      transformer
      |> put_handle(namespace, handle)
      |> Map.update!(:pending, &Map.delete(&1, {parent_namespace, parent_task_id}))
      |> Map.update!(:task_paths, &Map.put(&1, {parent_namespace, parent_task_id}, namespace))
      |> append_handle(parent_namespace, handle)
    else
      _other -> transformer
    end
  end

  defp maybe_finish_handle(%__MODULE__{} = transformer, namespace, data, raw_event) do
    if task_terminal?(data) and task_name(data) == "tools" do
      parent_task_id = data_value(data, :id) || data_value(data, :task_id)
      path = Map.get(transformer.task_paths, {namespace, parent_task_id})

      case path do
        nil ->
          transformer

        path ->
          {status, error} = terminal_status(data)

          update_handle(transformer, path, fn handle ->
            observed = observe_event(handle, raw_event, namespace, data, "tasks")
            %{observed | status: status, error: error || handle.error}
          end)
      end
    else
      transformer
    end
  end

  defp route_data(%__MODULE__{} = transformer, method, namespace, data, raw_event) do
    transformer
    |> matching_paths(namespace)
    |> Enum.reduce(transformer, fn path, acc ->
      update_handle(acc, path, &observe_event(&1, raw_event, namespace, data, method))
    end)
  end

  defp mark_namespace_terminal(%__MODULE__{} = transformer, namespace, status, error, raw_event) do
    transformer
    |> matching_paths(namespace)
    |> Enum.reduce(transformer, fn path, acc ->
      update_handle(acc, path, fn handle ->
        observed = observe_event(handle, raw_event, namespace, error, "error")
        %{observed | status: status, error: error || handle.error}
      end)
    end)
  end

  defp observe_event(%RunStream{} = handle, raw_event, _namespace, data, method) do
    handle
    |> Map.update!(:events, &(&1 ++ [raw_event]))
    |> maybe_append_value(method, data)
    |> maybe_append_update(method, data)
  end

  defp observe_event(%AsyncRunStream{} = handle, raw_event, _namespace, data, method) do
    handle
    |> Map.update!(:events, &(&1 ++ [raw_event]))
    |> maybe_append_value(method, data)
    |> maybe_append_update(method, data)
  end

  defp maybe_append_value(handle, "values", data),
    do: Map.update!(handle, :values, &(&1 ++ [data]))

  defp maybe_append_value(handle, _method, _data), do: handle

  defp maybe_append_update(handle, "updates", data),
    do: Map.update!(handle, :updates, &(&1 ++ [data]))

  defp maybe_append_update(handle, _method, _data), do: handle

  defp pending_info(tool_calls) when is_list(tool_calls) do
    Enum.find_value(tool_calls, fn
      tool_call when is_map(tool_call) ->
        if data_value(tool_call, :name) == "task" do
          args = data_value(tool_call, :args) || %{}
          subagent_type = data_value(args, :subagent_type) || data_value(args, :subagent_name)

          if is_binary(subagent_type) do
            %{
              subagent_type: subagent_type,
              tool_call_id: data_value(tool_call, :id),
              task_input: data_value(args, :description)
            }
          end
        end

      _other ->
        nil
    end)
  end

  defp pending_info(_tool_calls), do: nil

  defp new_handle(path, info, raw_event) do
    struct =
      if async_event?(raw_event),
        do: AsyncRunStream,
        else: RunStream

    struct(struct, %{
      path: path,
      graph_name: info.subagent_type,
      trigger_call_id: blank_to_nil(info.tool_call_id),
      task_input: blank_to_nil(info.task_input)
    })
  end

  defp append_handle(
         %__MODULE__{scope: parent_namespace} = transformer,
         parent_namespace,
         handle
       ),
       do: %{transformer | log: transformer.log ++ [handle]}

  defp append_handle(%__MODULE__{} = transformer, parent_namespace, handle) do
    update_handle(transformer, parent_namespace, fn parent ->
      Map.update!(parent, :subagents, &(&1 ++ [handle]))
    end)
  end

  defp put_handle(%__MODULE__{} = transformer, path, handle),
    do: %{transformer | handles: Map.put(transformer.handles, path, handle)}

  defp update_handle(%__MODULE__{} = transformer, path, fun) do
    case Map.fetch(transformer.handles, path) do
      {:ok, handle} ->
        new_handle = fun.(handle)
        handles = replace_handle_map(transformer.handles, path, new_handle)

        %{
          transformer
          | handles: handles,
            log: replace_handle(transformer.log, path, new_handle)
        }

      :error ->
        transformer
    end
  end

  defp replace_handle(handles, path, new_handle) do
    Enum.map(handles, fn
      %{path: ^path} ->
        new_handle

      %{subagents: subagents} = handle ->
        %{handle | subagents: replace_handle(subagents, path, new_handle)}

      handle ->
        handle
    end)
  end

  defp replace_handle_map(handles, path, new_handle) do
    Map.new(handles, fn
      {^path, _handle} -> {path, new_handle}
      {handle_path, handle} -> {handle_path, replace_handle_in_parent(handle, path, new_handle)}
    end)
  end

  defp replace_handle_in_parent(%{subagents: subagents} = handle, path, new_handle) do
    %{handle | subagents: replace_handle(subagents, path, new_handle)}
  end

  defp replace_handle_in_parent(handle, _path, _new_handle), do: handle

  defp matching_paths(%__MODULE__{} = transformer, namespace) do
    transformer.handles
    |> Map.keys()
    |> Enum.filter(&prefix?(&1, namespace))
    |> Enum.sort_by(&length/1, :desc)
    |> Enum.take(1)
  end

  defp parent_scope?(%__MODULE__{scope: scope, handles: handles}, namespace) do
    namespace == scope or Map.has_key?(handles, namespace)
  end

  defp parent_task_key(namespace) when is_list(namespace) and namespace != [] do
    {parent_namespace, [segment]} = Enum.split(namespace, length(namespace) - 1)

    case segment |> to_string() |> String.split(":", parts: 2) do
      [_node, task_id] when task_id != "" -> {parent_namespace, task_id}
      _other -> :error
    end
  end

  defp parent_task_key(_namespace), do: :error

  defp task_start?(data), do: not task_terminal?(data)

  defp task_terminal?(data) do
    Map.has_key?(data, :result) or Map.has_key?(data, "result") or
      not is_nil(data_value(data, :error)) or nonempty_list?(data_value(data, :interrupts))
  end

  defp task_name(data), do: data_value(data, :name) || data_value(data, :node)

  defp terminal_status(data) do
    cond do
      nonempty_list?(data_value(data, :interrupts)) ->
        {:interrupted, nil}

      not is_nil(data_value(data, :error)) ->
        {:failed, error_message(data_value(data, :error))}

      true ->
        {:completed, nil}
    end
  end

  defp normalize_event(%Envelope{event: %Events.Task{} = event, namespace: namespace}) do
    data =
      event.payload
      |> normalize_payload()
      |> Map.put_new(:id, event.task_id)
      |> Map.put_new(:name, to_string(event.node || ""))

    if event.kind in [:finish, :error],
      do: %{
        method: "tasks",
        namespace: Namespace.normalize(namespace, stringify: true),
        data: Map.put_new(data, :result, event.payload || %{})
      },
      else: %{
        method: "tasks",
        namespace: Namespace.normalize(namespace, stringify: true),
        data: data
      }
  end

  defp normalize_event(%Envelope{event: %Events.GraphValue{value: value}, namespace: namespace}),
    do: %{
      method: "values",
      namespace: Namespace.normalize(namespace, stringify: true),
      data: value
    }

  defp normalize_event(%Envelope{
         event: %Events.GraphUpdate{update: update},
         namespace: namespace
       }),
       do: %{
         method: "updates",
         namespace: Namespace.normalize(namespace, stringify: true),
         data: update
       }

  defp normalize_event(%Envelope{event: %Events.Error{error: error}, namespace: namespace}),
    do: %{
      method: "error",
      namespace: Namespace.normalize(namespace, stringify: true),
      data: error
    }

  defp normalize_event(%{"method" => method, "params" => params}),
    do: normalize_protocol(method, params)

  defp normalize_event(%{method: method, params: params}),
    do: normalize_protocol(method, params)

  defp normalize_event(%{method: method} = event),
    do: %{
      method: to_string(method),
      namespace: Namespace.normalize(data_value(event, :namespace, []), stringify: true),
      data: data_value(event, :data, %{})
    }

  defp normalize_event(_event), do: nil

  defp normalize_protocol(method, params) when is_map(params) do
    %{
      method: to_string(method),
      namespace: Namespace.normalize(data_value(params, :namespace, []), stringify: true),
      data: data_value(params, :data, %{})
    }
  end

  defp normalize_protocol(method, _params),
    do: %{method: to_string(method), namespace: [], data: %{}}

  defp normalize_payload(payload) when is_map(payload), do: payload
  defp normalize_payload(nil), do: %{}
  defp normalize_payload(payload), do: %{input: payload}

  defp normalize_names(names) do
    names
    |> List.wrap()
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&to_string/1)
    |> MapSet.new()
  end

  defp data_value(map, key, default \\ nil)

  defp data_value(map, key, default) when is_map(map),
    do: Map.get(map, key, Map.get(map, to_string(key), default))

  defp data_value(_map, _key, default), do: default

  defp prefix?(prefix, list), do: Enum.take(list, length(prefix)) == prefix

  defp nonempty_list?(value), do: is_list(value) and value != []

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

  defp interrupted?(%Error{type: type}) when type in [:graph_interrupt, :interrupted], do: true
  defp interrupted?(%{type: type}) when type in [:graph_interrupt, :interrupted], do: true

  defp interrupted?(%{"type" => type})
       when type in [:graph_interrupt, :interrupted, "graph_interrupt", "interrupted"], do: true

  defp interrupted?(_reason), do: false

  defp error_message(%Error{message: message}), do: message
  defp error_message(%{message: message}) when is_binary(message), do: message
  defp error_message(%{"message" => message}) when is_binary(message), do: message
  defp error_message(error) when is_binary(error), do: error
  defp error_message(nil), do: nil
  defp error_message(error), do: inspect(error)

  defp async_event?(%Envelope{metadata: metadata}),
    do: data_value(metadata || %{}, :async) == true

  defp async_event?(%{"params" => params}),
    do: data_value(data_value(params, :metadata, %{}), :async) == true

  defp async_event?(%{params: params}),
    do: data_value(data_value(params, :metadata, %{}), :async) == true

  defp async_event?(_event), do: false
end
