defmodule BeamWeaver.Agent.Subagent.RunStream do
  @moduledoc """
  Immutable summary of one subagent run, built from stream events.

  It holds the declared subagent name, the tool call that started the run (see
  `cause/1`), the latest output, the terminal status, nested subagents, and the
  events observed under the run path.
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

defmodule BeamWeaver.Agent.Subagent.StreamTransformer do
  @moduledoc """
  Projects the subagent runs of an agent's stream into
  `BeamWeaver.Agent.Subagent.RunStream` summaries.

  Feed it the events of `BeamWeaver.Agent.stream_events/3` for an agent with
  `subagents`. Each `task` call to a subagent named in `subagent_names:`
  becomes one run: the subagent's name, the call that started it, its task,
  status, events, values and updates, and the runs of its own subagents. A run
  is matched to its events by the `tool_call_id` in their envelope metadata.

      {:ok, events} = MyApp.SupportResearcher.stream_events(input, live: true)
      transformer = StreamTransformer.new(subagent_names: ["policy_expert"])
      {:ok, transformer, _runs} = StreamTransformer.process_many(transformer, events)
      StreamTransformer.finalize(transformer).log

  It also reads Agent Protocol events, where a subagent run's namespace is
  `tools:<task id>` under the task that started it.
  """

  alias BeamWeaver.Agent.Subagent.RunStream
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Stream.Envelope
  alias BeamWeaver.Stream.Events
  alias BeamWeaver.Stream.Namespace

  import BeamWeaver.Agent.Subagent.Helpers, only: [value: 2, value: 3]

  defstruct scope: [],
            subagent_names: MapSet.new(),
            pending: %{},
            task_paths: %{},
            calls: %{},
            handles: %{},
            log: []

  @type t :: %__MODULE__{
          scope: [String.t()],
          subagent_names: MapSet.t(String.t()),
          pending: map(),
          task_paths: map(),
          calls: map(),
          handles: %{optional(term()) => RunStream.t()},
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
  def process(%__MODULE__{} = transformer, %Envelope{event: event} = envelope)
      when is_struct(event, Events.ToolStart) or is_struct(event, Events.ToolFinish) or
             is_struct(event, Events.ToolError) or is_map_key(envelope.metadata, :tool_call_id) or
             is_struct(event, Events.Debug) do
    transformer
    |> observe_subagent_event(envelope)
    |> start_task_call(envelope)
    |> finish_task_call(envelope)
    |> interrupt_open_runs(envelope)
    |> emit_result(transformer)
  end

  def process(%__MODULE__{} = transformer, event) do
    case normalize_event(event) do
      %{method: "tasks", namespace: namespace, data: data} ->
        transformer
        |> capture_pending(namespace, data)
        |> maybe_start_handle(namespace, data)
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
  def finalize(%__MODULE__{} = transformer), do: update_started(transformer, &%{&1 | status: :completed})

  @spec fail(t(), term()) :: t()
  def fail(%__MODULE__{} = transformer, reason) do
    status = if interrupted?(reason), do: :interrupted, else: :failed
    message = if status == :failed, do: error_message(reason), else: nil
    update_started(transformer, &%{&1 | status: status, error: message || &1.error})
  end

  defp update_started(transformer, fun) do
    transformer.handles
    |> Enum.filter(fn {_key, handle} -> handle.status == :started end)
    |> Enum.reduce(transformer, fn {key, _handle}, acc -> update_handle(acc, key, fun) end)
  end

  defp emit_result(%__MODULE__{} = next, %__MODULE__{} = previous) do
    new_keys = Map.keys(next.handles) -- Map.keys(previous.handles)
    new_handles = Enum.map(new_keys, &Map.fetch!(next.handles, &1))

    if next == previous and new_handles == [],
      do: {:pass, next},
      else: {:ok, next, new_handles}
  end

  # Subagent events forwarded by the `task` tool carry the call's id in their
  # envelope metadata; the call's `ToolStart` names the subagent.

  defp start_task_call(transformer, %Envelope{event: %Events.ToolStart{tool_name: "task"} = start} = envelope) do
    input = start.input || %{}
    subagent_type = value(input, :subagent_type) || value(input, :subagent_name)
    parent = Map.get(transformer.calls, envelope_call_id(envelope))

    cond do
      not MapSet.member?(transformer.subagent_names, to_string(subagent_type)) ->
        transformer

      is_nil(parent) and Namespace.normalize(envelope.namespace, stringify: true) != transformer.scope ->
        transformer

      true ->
        info = %{
          subagent_type: to_string(subagent_type),
          task_input: value(input, :description),
          parent: parent
        }

        %{transformer | pending: Map.put(transformer.pending, {:call, start.tool_call_id}, info)}
    end
  end

  defp start_task_call(transformer, _envelope), do: transformer

  defp observe_subagent_event(transformer, %Envelope{} = envelope) do
    call_id = envelope_call_id(envelope)

    case {Map.get(transformer.calls, call_id), Map.get(transformer.pending, {:call, call_id})} do
      {nil, nil} ->
        transformer

      {nil, info} ->
        path = Namespace.normalize(envelope.namespace, stringify: true)
        handle = %{new_handle(path, %{info | parent: nil} |> Map.put(:tool_call_id, call_id)) | path: path}
        key = handle_key(handle)

        transformer
        |> put_handle(key, handle)
        |> Map.update!(:pending, &Map.delete(&1, {:call, call_id}))
        |> Map.update!(:calls, &Map.put(&1, call_id, key))
        |> attach_handle(info.parent, handle)
        |> observe_call_event(key, envelope)

      {key, _info} ->
        observe_call_event(transformer, key, envelope)
    end
  end

  defp observe_call_event(transformer, key, %Envelope{event: event, namespace: namespace} = envelope) do
    {data, method} =
      case {Namespace.normalize(namespace, stringify: true) == elem(key, 0), event} do
        {true, %Events.GraphValue{value: value}} -> {value, "values"}
        {true, %Events.GraphUpdate{update: update}} -> {update, "updates"}
        _other -> {nil, nil}
      end

    update_handle(transformer, key, &observe_event(&1, envelope, data, method))
  end

  defp finish_task_call(transformer, %Envelope{event: %Events.ToolFinish{tool_call_id: call_id}}),
    do: finish_call(transformer, call_id, :completed, nil)

  defp finish_task_call(transformer, %Envelope{event: %Events.ToolError{tool_call_id: call_id, message: message}}),
    do: finish_call(transformer, call_id, :failed, message)

  defp finish_task_call(transformer, _envelope), do: transformer

  defp finish_call(transformer, call_id, status, error) do
    case Map.get(transformer.calls, call_id) do
      nil -> transformer
      key -> update_handle(transformer, key, &%{&1 | status: status, error: error || &1.error})
    end
  end

  defp interrupt_open_runs(transformer, %Envelope{event: %Events.Debug{payload: %{type: :interrupt}}}),
    do: fail(transformer, %{type: :interrupted})

  defp interrupt_open_runs(transformer, _envelope), do: transformer

  defp envelope_call_id(%Envelope{metadata: metadata}) when is_map(metadata), do: Map.get(metadata, :tool_call_id)
  defp envelope_call_id(_envelope), do: nil

  defp attach_handle(transformer, nil, handle), do: %{transformer | log: transformer.log ++ [handle]}

  defp attach_handle(transformer, parent_key, handle),
    do: update_handle(transformer, parent_key, &Map.update!(&1, :subagents, fn subagents -> subagents ++ [handle] end))

  # Agent Protocol events: a run's namespace is `tools:<task id>` under the
  # `tools` task whose input holds the `task` call.

  defp capture_pending(%__MODULE__{} = transformer, namespace, data) do
    if parent_scope?(transformer, namespace) and task_start?(data) and task_name(data) == "tools" do
      parent_task_id = value(data, :id) || value(data, :task_id)
      tool_calls = value(data, :input)

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

  defp maybe_start_handle(%__MODULE__{} = transformer, namespace, data) do
    with true <- task_start?(data),
         {parent_namespace, parent_task_id} <- parent_task_key(namespace),
         true <- parent_scope?(transformer, parent_namespace),
         info when not is_nil(info) <-
           Map.get(transformer.pending, {parent_namespace, parent_task_id}),
         true <- MapSet.member?(transformer.subagent_names, info.subagent_type),
         nil <- path_key(transformer, namespace) do
      handle = new_handle(namespace, info)
      key = handle_key(handle)

      transformer
      |> put_handle(key, handle)
      |> Map.update!(:pending, &Map.delete(&1, {parent_namespace, parent_task_id}))
      |> Map.update!(:task_paths, &Map.put(&1, {parent_namespace, parent_task_id}, key))
      |> attach_handle(path_key(transformer, parent_namespace), handle)
    else
      _other -> transformer
    end
  end

  defp maybe_finish_handle(%__MODULE__{} = transformer, namespace, data, raw_event) do
    if task_terminal?(data) and task_name(data) == "tools" do
      parent_task_id = value(data, :id) || value(data, :task_id)

      case Map.get(transformer.task_paths, {namespace, parent_task_id}) do
        nil ->
          transformer

        key ->
          {status, error} = terminal_status(data)

          update_handle(transformer, key, fn handle ->
            observed = observe_event(handle, raw_event, data, "tasks")
            %{observed | status: status, error: error || handle.error}
          end)
      end
    else
      transformer
    end
  end

  defp route_data(%__MODULE__{} = transformer, method, namespace, data, raw_event) do
    transformer
    |> matching_keys(namespace)
    |> Enum.reduce(transformer, fn key, acc ->
      update_handle(acc, key, &observe_event(&1, raw_event, data, method))
    end)
  end

  defp mark_namespace_terminal(%__MODULE__{} = transformer, namespace, status, error, raw_event) do
    transformer
    |> matching_keys(namespace)
    |> Enum.reduce(transformer, fn key, acc ->
      update_handle(acc, key, fn handle ->
        observed = observe_event(handle, raw_event, error, "error")
        %{observed | status: status, error: error || handle.error}
      end)
    end)
  end

  defp observe_event(%RunStream{} = handle, raw_event, data, method) do
    handle = Map.update!(handle, :events, &(&1 ++ [raw_event]))

    case method do
      "values" -> Map.update!(handle, :values, &(&1 ++ [data]))
      "updates" -> Map.update!(handle, :updates, &(&1 ++ [data]))
      _other -> handle
    end
  end

  defp pending_info(tool_calls) when is_list(tool_calls) do
    Enum.find_value(tool_calls, fn
      tool_call when is_map(tool_call) ->
        if value(tool_call, :name) == "task" do
          args = value(tool_call, :args) || %{}
          subagent_type = value(args, :subagent_type) || value(args, :subagent_name)

          if is_binary(subagent_type) do
            %{
              subagent_type: subagent_type,
              tool_call_id: value(tool_call, :id),
              task_input: value(args, :description)
            }
          end
        end

      _other ->
        nil
    end)
  end

  defp pending_info(_tool_calls), do: nil

  defp new_handle(path, info) do
    %RunStream{
      path: path,
      graph_name: info.subagent_type,
      trigger_call_id: blank_to_nil(info.tool_call_id),
      task_input: blank_to_nil(info.task_input)
    }
  end

  # A run is known by its path and the call that started it, so parallel calls
  # to one subagent stay apart.
  defp handle_key(%RunStream{path: path, trigger_call_id: call_id}), do: {path, call_id}

  defp put_handle(%__MODULE__{} = transformer, key, handle),
    do: %{transformer | handles: Map.put(transformer.handles, key, handle)}

  defp update_handle(%__MODULE__{} = transformer, key, fun) do
    case Map.fetch(transformer.handles, key) do
      {:ok, handle} ->
        new_handle = fun.(handle)

        %{
          transformer
          | handles: replace_handle_map(transformer.handles, key, new_handle),
            log: replace_handle(transformer.log, key, new_handle)
        }

      :error ->
        transformer
    end
  end

  defp replace_handle(handles, key, new_handle) do
    Enum.map(handles, fn handle ->
      if handle_key(handle) == key do
        new_handle
      else
        %{handle | subagents: replace_handle(handle.subagents, key, new_handle)}
      end
    end)
  end

  defp replace_handle_map(handles, key, new_handle) do
    Map.new(handles, fn
      {^key, _handle} -> {key, new_handle}
      {handle_key, handle} -> {handle_key, %{handle | subagents: replace_handle(handle.subagents, key, new_handle)}}
    end)
  end

  defp path_key(%__MODULE__{handles: handles}, path) do
    Enum.find_value(handles, fn {{handle_path, _call_id} = key, _handle} -> if handle_path == path, do: key end)
  end

  defp matching_keys(%__MODULE__{} = transformer, namespace) do
    transformer.handles
    |> Map.keys()
    |> Enum.filter(fn {path, _call_id} -> prefix?(path, namespace) end)
    |> Enum.sort_by(fn {path, _call_id} -> length(path) end, :desc)
    |> Enum.take(1)
  end

  defp parent_scope?(%__MODULE__{scope: scope} = transformer, namespace) do
    namespace == scope or not is_nil(path_key(transformer, namespace))
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
      not is_nil(value(data, :error)) or nonempty_list?(value(data, :interrupts))
  end

  defp task_name(data), do: value(data, :name) || value(data, :node)

  defp terminal_status(data) do
    cond do
      nonempty_list?(value(data, :interrupts)) ->
        {:interrupted, nil}

      not is_nil(value(data, :error)) ->
        {:failed, error_message(value(data, :error))}

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

    data = if event.kind in [:finish, :error], do: Map.put_new(data, :result, event.payload || %{}), else: data
    envelope_event("tasks", namespace, data)
  end

  defp normalize_event(%Envelope{event: %Events.GraphValue{value: value}, namespace: namespace}),
    do: envelope_event("values", namespace, value)

  defp normalize_event(%Envelope{event: %Events.GraphUpdate{update: update}, namespace: namespace}),
    do: envelope_event("updates", namespace, update)

  defp normalize_event(%Envelope{event: %Events.Error{error: error}, namespace: namespace}),
    do: envelope_event("error", namespace, error)

  defp normalize_event(%{"method" => method, "params" => params}),
    do: normalize_protocol(method, params)

  defp normalize_event(%{method: method, params: params}),
    do: normalize_protocol(method, params)

  defp normalize_event(%{method: method} = event), do: normalize_protocol(method, event)

  defp normalize_event(_event), do: nil

  defp envelope_event(method, namespace, data),
    do: %{method: method, namespace: Namespace.normalize(namespace, stringify: true), data: data}

  defp normalize_protocol(method, params) when is_map(params) do
    %{
      method: to_string(method),
      namespace: Namespace.normalize(value(params, :namespace, []), stringify: true),
      data: value(params, :data, %{})
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

  defp prefix?(prefix, list), do: Enum.take(list, length(prefix)) == prefix

  defp nonempty_list?(value), do: is_list(value) and value != []

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

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
end
