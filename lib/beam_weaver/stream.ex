defprotocol BeamWeaver.Stream.IntoEvent do
  @fallback_to_any true
  def into_event(value)
end

defprotocol BeamWeaver.Stream.Finalize do
  @fallback_to_any true
  def finalize(value)
end

defmodule BeamWeaver.Stream do
  @moduledoc """
  Typed stream event helpers.
  """

  alias BeamWeaver.Core.Error
  alias BeamWeaver.MapShape
  alias BeamWeaver.Stream.Envelope
  alias BeamWeaver.Stream.Events
  alias BeamWeaver.Stream.Namespace

  @event_specs %{
    Events.GraphValue => %{name: :graph_value, mode: :values},
    Events.GraphUpdate => %{name: :graph_update, mode: :updates},
    Events.Message => %{name: :message, mode: :messages},
    Events.MessageChunk => %{name: :message_chunk, mode: :messages},
    Events.Token => %{name: :token, mode: :messages},
    Events.ToolCallChunk => %{name: :tool_call_chunk, mode: :messages},
    Events.ToolStart => %{name: :tool_start, mode: :tools},
    Events.ToolDelta => %{name: :tool_delta, mode: :tools},
    Events.ToolFinish => %{name: :tool_finish, mode: :tools},
    Events.ToolError => %{name: :tool_error, mode: :tools},
    Events.Checkpoint => %{name: :checkpoint, mode: :checkpoints},
    Events.Task => %{name: :task, mode: :tasks},
    Events.Lifecycle => %{name: :lifecycle, mode: :lifecycle},
    Events.Debug => %{name: :debug, mode: :debug},
    Events.Custom => %{name: :custom, mode: :custom},
    Events.Error => %{name: :error, mode: :debug},
    Events.Done => %{name: :done, mode: :debug}
  }

  @custom_event_spec %{name: :custom, mode: :custom}

  @modes [
    :events,
    :values,
    :updates,
    :custom,
    :messages,
    :tools,
    :checkpoints,
    :tasks,
    :debug,
    :lifecycle
  ]

  @spec envelope(term(), keyword() | map()) :: Envelope.t()
  def envelope(event, opts \\ []) do
    opts = if is_map(opts), do: Map.to_list(opts), else: opts

    %Envelope{
      event: BeamWeaver.Stream.IntoEvent.into_event(event),
      run_id: Keyword.get(opts, :run_id),
      graph: Keyword.get(opts, :graph),
      node: Keyword.get(opts, :node),
      task_id: Keyword.get(opts, :task_id),
      step: Keyword.get(opts, :step),
      namespace: Namespace.normalize(Keyword.get(opts, :namespace, [])),
      metadata: Keyword.get(opts, :metadata, %{}),
      timestamp: Keyword.get(opts, :timestamp, System.system_time(:microsecond))
    }
  end

  @spec event(atom(), term()) :: term()
  def event(:token, text), do: %Events.Token{text: text}
  def event(:message_chunk, chunk), do: %Events.MessageChunk{chunk: chunk}
  def event(:message, message), do: %Events.Message{message: message}
  def event(:tool_call_chunk, chunk), do: %Events.ToolCallChunk{chunk: chunk}
  def event(:tool_start, attrs), do: struct(Events.ToolStart, map_or_keyword(attrs))
  def event(:tool_delta, attrs), do: struct(Events.ToolDelta, map_or_keyword(attrs))
  def event(:tool_finish, attrs), do: struct(Events.ToolFinish, map_or_keyword(attrs))
  def event(:tool_error, attrs), do: struct(Events.ToolError, map_or_keyword(attrs))
  def event(:graph_update, update), do: %Events.GraphUpdate{update: update}
  def event(:graph_value, value), do: %Events.GraphValue{value: value}
  def event(:checkpoint, attrs), do: struct(Events.Checkpoint, map_or_keyword(attrs))
  def event(:task, attrs), do: struct(Events.Task, map_or_keyword(attrs))
  def event(:lifecycle, attrs), do: struct(Events.Lifecycle, map_or_keyword(attrs))
  def event(:debug, payload), do: %Events.Debug{payload: payload}
  def event(:custom, payload), do: %Events.Custom{payload: payload}
  def event(:error, error), do: %Events.Error{error: error}
  def event(:done, attrs), do: struct(Events.Done, map_or_keyword(attrs))

  @spec normalize_mode(atom() | String.t()) :: atom()
  def normalize_mode(mode) when is_atom(mode) and mode in @modes, do: mode

  def normalize_mode(mode) when is_binary(mode) do
    mode
    |> String.to_existing_atom()
    |> normalize_mode()
  rescue
    ArgumentError -> :updates
  end

  def normalize_mode(_mode), do: :updates

  @spec mode?(MapSet.t(atom()) | [atom()] | atom(), atom()) :: boolean()
  def mode?(%MapSet{} = modes, mode), do: MapSet.member?(modes, mode)
  def mode?(modes, mode) when is_list(modes), do: mode in modes
  def mode?(mode, mode), do: true
  def mode?(_modes, _mode), do: false

  @spec event_mode(term()) :: atom()
  def event_mode(event), do: stream_mode(event)

  @spec format(Envelope.t(), MapSet.t(atom()) | [atom()] | atom()) :: term()
  def format(%Envelope{} = envelope, modes) do
    _modes = modes
    emit(:event, %{count: 1}, telemetry_metadata(envelope))
    envelope
  end

  @spec to_langsmith_event(Envelope.t()) :: map()
  def to_langsmith_event(%Envelope{} = envelope) do
    %{
      event: envelope.event |> event_name() |> Atom.to_string(),
      data: event_data(envelope.event),
      metadata: envelope.metadata,
      run_id: envelope.run_id,
      name: envelope.node,
      tags: Map.get(envelope.metadata || %{}, :tags, []),
      namespace: envelope.namespace
    }
    |> Map.put(:graph, envelope.graph)
    |> Map.put(:step, envelope.step)
    |> Map.put(:task_id, envelope.task_id)
    |> maybe_put_metadata_value(envelope, :model_provider, [:model_provider, :provider])
    |> maybe_put_metadata_value(envelope, :model_name, [:model_name, :model])
    |> maybe_put_metadata_value(envelope, :invocation_params, [:invocation_params, :params])
    |> maybe_put_token_usage(envelope)
    |> maybe_put_metadata_value(envelope, :tool_calls, [:tool_calls])
    |> maybe_put_metadata_value(envelope, :retriever, [:retriever])
    |> maybe_put_metadata_value(envelope, :vectorstore, [:vectorstore, :vector_store])
    |> MapShape.compact()
  end

  defp maybe_put_token_usage(map, %Envelope{event: %Events.Done{usage: usage}})
       when not is_nil(usage),
       do: Map.put(map, :token_usage, usage)

  defp maybe_put_token_usage(map, envelope),
    do:
      maybe_put_metadata_value(map, envelope, :token_usage, [
        :token_usage,
        :usage,
        :usage_metadata
      ])

  @spec emit(atom(), map(), map()) :: :ok
  def emit(event, measurements, metadata) do
    if Code.ensure_loaded?(:telemetry) do
      :telemetry.execute([:beam_weaver, :stream, event], measurements, metadata)
    end

    :ok
  end

  @doc """
  Builds a producer-backed stream that cancels the producer when the consumer halts.

  The producer receives a sink function. Calling the sink emits one item to the
  returned enumerable. Producer completion should return `:ok` or
  `{:error, tagged_error}`.
  """
  @spec live_resource((function() -> term()), keyword()) :: Enumerable.t()
  def live_resource(producer, opts \\ []) when is_function(producer, 1) do
    timeout = Keyword.get(opts, :timeout, :infinity)
    on_cancel = Keyword.get(opts, :on_cancel, fn -> :ok end)
    producer_supervisor = Keyword.get(opts, :producer_supervisor)

    Stream.resource(
      fn ->
        parent = self()

        task =
          start_live_resource_task(producer_supervisor, fn ->
            result =
              try do
                producer.(fn item -> send(parent, {:beam_weaver_stream_item, self(), item}) end)
              rescue
                exception ->
                  {:error,
                   Error.new(:stream_error, Exception.message(exception), %{
                     exception: inspect(exception.__struct__)
                   })}
              catch
                kind, reason ->
                  {:error,
                   Error.new(:stream_error, "stream producer exited", %{
                     kind: kind,
                     reason: inspect(reason)
                   })}
              end

            send(
              parent,
              {:beam_weaver_stream_done, self(), normalize_live_resource_result(result)}
            )
          end)

        %{task: task, timeout: timeout, done?: false, on_cancel: on_cancel}
      end,
      fn
        %{done?: true} = state ->
          {:halt, state}

        %{task: task, timeout: timeout} = state ->
          receive do
            {:beam_weaver_stream_item, _producer, item} ->
              {[item], state}

            {:beam_weaver_stream_done, _producer, :ok} ->
              {:halt, %{state | done?: true}}

            {:beam_weaver_stream_done, _producer, {:error, error}} ->
              {[%Events.Error{error: error}], %{state | done?: true}}

            {:DOWN, ref, :process, _pid, reason} when ref == task.ref ->
              {[%Events.Error{error: reason}], %{state | done?: true}}
          after
            timeout ->
              {[%Events.Debug{payload: %{type: :heartbeat}}], state}
          end
      end,
      fn %{task: task, done?: done?, on_cancel: on_cancel} ->
        unless done? do
          Task.shutdown(task, :brutal_kill)
          on_cancel.()
          emit(:cancel, %{count: 1}, %{})
        end
      end
    )
  end

  defp start_live_resource_task(nil, fun), do: Task.async(fun)

  defp start_live_resource_task(supervisor, fun),
    do: Task.Supervisor.async_nolink(supervisor, fun)

  defp normalize_live_resource_result(result) when result in [:ok, nil], do: :ok
  defp normalize_live_resource_result({:ok, _value}), do: :ok
  defp normalize_live_resource_result({:error, %Error{} = error}), do: {:error, error}

  defp normalize_live_resource_result({:error, %{__struct__: _module, type: type, message: message} = error})
       when is_atom(type) and is_binary(message),
       do: {:error, error}

  defp normalize_live_resource_result({:error, reason}),
    do: {:error, Error.new(:stream_error, "stream producer failed", %{reason: inspect(reason)})}

  defp normalize_live_resource_result(_result), do: :ok

  @doc """
  Multiplexes one or more live producers into a lazy stream of typed envelopes.
  """
  def mux(producers, opts \\ []) when is_list(producers) do
    BeamWeaver.Stream.Mux.stream(producers, opts)
  end

  defp stream_mode(event), do: event |> event_spec() |> Map.fetch!(:mode)
  defp event_name(event), do: event |> event_spec() |> Map.fetch!(:name)

  defp event_spec(%{__struct__: module}), do: Map.get(@event_specs, module, @custom_event_spec)
  defp event_spec(_event), do: @custom_event_spec

  defp map_or_keyword(attrs) when is_map(attrs), do: attrs
  defp map_or_keyword(attrs) when is_list(attrs), do: Map.new(attrs)
  defp map_or_keyword(_attrs), do: %{}

  defp telemetry_metadata(%Envelope{} = envelope) do
    %{
      run_id: envelope.run_id,
      graph: envelope.graph,
      node: envelope.node,
      task_id: envelope.task_id,
      step: envelope.step,
      namespace: envelope.namespace,
      event: event_name(envelope.event)
    }
    |> MapShape.compact()
  end

  defp event_data(event) when is_map(event) do
    event
    |> Map.from_struct()
    |> MapShape.compact()
  rescue
    _error -> event
  end

  defp event_data(event), do: event

  defp maybe_put_metadata_value(map, %Envelope{} = envelope, out_key, metadata_keys) do
    metadata = envelope.metadata || %{}
    value = BeamWeaver.MapAccess.first(metadata, metadata_keys)

    if is_nil(value), do: map, else: Map.put(map, out_key, value)
  end
end

defimpl BeamWeaver.Stream.IntoEvent, for: Any do
  alias BeamWeaver.Stream.Events

  def into_event(%{type: :tool_event, payload: payload}), do: tool_event(payload)

  def into_event(%{type: :message, message: message} = payload),
    do: %Events.Message{message: message, metadata: Map.get(payload, :metadata, %{})}

  def into_event(%{type: :ui, message: message}), do: %Events.Custom{payload: message}
  def into_event(value), do: %Events.Custom{payload: value}

  defp tool_event(%{event: "tool-started"} = payload) do
    %Events.ToolStart{
      tool_call_id: Map.get(payload, :tool_call_id),
      tool_name: Map.get(payload, :tool_name),
      input: Map.get(payload, :input, %{})
    }
  end

  defp tool_event(%{event: "tool-output-delta"} = payload) do
    %Events.ToolDelta{
      tool_call_id: Map.get(payload, :tool_call_id),
      delta: Map.get(payload, :delta)
    }
  end

  defp tool_event(%{event: "tool-finished"} = payload) do
    %Events.ToolFinish{
      tool_call_id: Map.get(payload, :tool_call_id),
      output: Map.get(payload, :output)
    }
  end

  defp tool_event(%{event: "tool-error"} = payload) do
    %Events.ToolError{
      tool_call_id: Map.get(payload, :tool_call_id),
      message: Map.get(payload, :message),
      error_type: Map.get(payload, :error_type)
    }
  end

  defp tool_event(payload), do: %Events.Custom{payload: payload}
end

defimpl BeamWeaver.Stream.Finalize, for: Any do
  def finalize(value), do: value
end
