defmodule BeamWeaver.Tracing do
  @moduledoc """
  Local run trees, context propagation, redaction, and exporter boundaries.
  """

  alias BeamWeaver.Config
  alias BeamWeaver.Tracing.Context
  alias BeamWeaver.Tracing.Run
  alias BeamWeaver.Tracing.Store

  @type run_ref :: Run.t() | Run.id()

  @doc """
  Starts a trace run and makes it the current process context.
  """
  @spec start_run(String.t() | atom(), keyword()) :: {:ok, Run.t()}
  def start_run(name, opts \\ []) do
    parent_context = Context.current()
    parent_id = Keyword.get(opts, :parent_id) || context_run_id(parent_context)
    trace_id = Keyword.get(opts, :trace_id) || context_trace_id(parent_context)

    run_opts =
      opts
      |> Keyword.put(:parent_id, parent_id)
      |> Keyword.put(:trace_id, trace_id)
      |> Keyword.put(:tags, merge_context_tags(parent_context, Keyword.get(opts, :tags, [])))
      |> Keyword.put(
        :metadata,
        merge_context_metadata(parent_context, Keyword.get(opts, :metadata, %{}))
      )

    run = Run.new(name, run_opts)

    :ok = Store.put(run)
    export(:started, run, opts)
    Context.put(Context.from_run(run))

    {:ok, run}
  end

  @doc """
  Finishes a trace run successfully.
  """
  @spec finish_run(run_ref(), keyword()) :: {:ok, Run.t()} | :error
  def finish_run(run_ref, opts \\ []) do
    update_run(run_ref, :ok, opts, fn run ->
      %{
        run
        | status: :ok,
          ended_at: timestamp(),
          outputs: BeamWeaver.Tracing.Redactor.redact(Keyword.get(opts, :outputs, run.outputs)),
          metadata: merge_redacted(run.metadata, Keyword.get(opts, :metadata, %{})),
          usage: merge_redacted(run.usage, Keyword.get(opts, :usage, %{}))
      }
    end)
  end

  @doc """
  Marks a trace run as failed.
  """
  @spec fail_run(run_ref(), term(), keyword()) :: {:ok, Run.t()} | :error
  def fail_run(run_ref, error, opts \\ []) do
    update_run(run_ref, :error, opts, fn run ->
      %{
        run
        | status: :error,
          ended_at: timestamp(),
          error: BeamWeaver.Tracing.Redactor.redact(error_to_map(error)),
          outputs: BeamWeaver.Tracing.Redactor.redact(Keyword.get(opts, :outputs, run.outputs)),
          metadata: merge_redacted(run.metadata, Keyword.get(opts, :metadata, %{})),
          usage: merge_redacted(run.usage, Keyword.get(opts, :usage, %{}))
      }
    end)
  end

  @doc """
  Runs `fun` inside a trace run, finishing or failing the run automatically.
  """
  @spec with_run(String.t() | atom(), keyword(), (-> term())) :: term()
  def with_run(name, opts \\ [], fun) when is_function(fun, 0) do
    previous_context = capture_context()
    {:ok, run} = start_run(name, opts)

    try do
      result = fun.()
      finish_run(run, opts)
      result
    rescue
      exception ->
        fail_run(run, exception, opts)
        reraise exception, __STACKTRACE__
    catch
      kind, reason ->
        fail_run(run, %{kind: kind, reason: reason}, opts)
        :erlang.raise(kind, reason, __STACKTRACE__)
    after
      restore_context(previous_context)
    end
  end

  @doc """
  Runs `fun` inside a chain/group trace run.

  This is the BeamWeaver-native counterpart to Python's callback-manager chain
  grouping helpers. It records a normal trace run with `kind: :chain` and relies on
  process context propagation instead of passing callback manager objects around.
  """
  @spec with_chain_group(String.t() | atom(), keyword(), (-> term())) :: term()
  def with_chain_group(name, opts \\ [], fun) when is_function(fun, 0) do
    with_run(name, Keyword.put_new(opts, :kind, :chain), fun)
  end

  @doc """
  Emits a custom tracing event through `:telemetry` with the current trace context.

  Consumers that used Python callback handlers should subscribe to
  `[:beam_weaver, :tracing, :event]` and branch on the `:event` metadata field.
  """
  @spec dispatch_event(atom() | String.t(), term(), keyword()) :: :ok
  def dispatch_event(event, payload \\ %{}, opts \\ []) do
    context = capture_context()

    metadata =
      %{
        event: normalize_event(event),
        payload: payload,
        run_id: context_run_id(context),
        trace_id: context_trace_id(context),
        tags: normalize_tags(Keyword.get(opts, :tags, [])),
        metadata: Keyword.get(opts, :metadata, %{})
      }
      |> Enum.reject(fn
        {_key, nil} -> true
        {_key, []} -> true
        {_key, value} when is_map(value) and map_size(value) == 0 -> true
        _entry -> false
      end)
      |> Map.new()

    BeamWeaver.Telemetry.emit([:beam_weaver, :tracing, :event], %{count: 1}, metadata)
  end

  @doc """
  Captures the current trace context for propagation to another process.
  """
  @spec capture_context() :: Context.t() | nil
  defdelegate capture_context(), to: Context, as: :current

  @doc """
  Runs `fun` with a previously captured trace context.
  """
  @spec attach_context(Context.t() | nil, (-> term())) :: term()
  defdelegate attach_context(context, fun), to: Context, as: :attach

  @doc """
  Starts a task under `supervisor` with the current trace context attached.
  """
  @spec async(Supervisor.supervisor(), (-> term()), keyword()) :: Task.t()
  def async(supervisor, fun, opts \\ []) when is_function(fun, 0) do
    context = capture_context()
    task_opts = Keyword.take(opts, [:shutdown])

    Task.Supervisor.async_nolink(
      supervisor,
      fn ->
        attach_context(context, fun)
      end,
      task_opts
    )
  end

  @doc """
  Returns a stored run.
  """
  @spec get_run(Run.id()) :: {:ok, Run.t()} | :error
  defdelegate get_run(run_id), to: Store, as: :get

  @doc """
  Returns a run with nested child runs.
  """
  @spec get_tree(Run.id()) :: {:ok, map()} | :error
  defdelegate get_tree(run_id), to: Store, as: :tree

  @doc false
  defdelegate reset(), to: Store

  @doc """
  Flushes the configured tracing exporter when it supports explicit draining.

  This is useful for short-lived scripts that exit immediately after a run
  completes. Long-lived applications can rely on the supervised exporter queue.
  """
  @spec flush_exporter(timeout()) :: :ok | {:error, term()}
  def flush_exporter(timeout \\ 60_000) when is_integer(timeout) and timeout > 0 do
    exporter = Config.get([:tracing, :exporter])
    exporter_opts = Config.get([:tracing, :exporter_opts], [])

    cond do
      is_nil(exporter) ->
        :ok

      exporter == BeamWeaver.Tracing.Exporters.LangSmith.Queue ->
        queue = Keyword.get(exporter_opts, :queue, BeamWeaver.Tracing.Exporters.LangSmith.Queue)
        BeamWeaver.Tracing.Exporters.LangSmith.Queue.flush(queue, timeout)

      function_exported?(exporter, :flush, 1) ->
        exporter.flush(timeout)

      true ->
        :ok
    end
  end

  defp update_run(run_ref, event, opts, updater) do
    run_id = run_id(run_ref)

    case Store.update(run_id, updater) do
      {:ok, run} ->
        export(event, run, opts)
        pop_finished_context(run)
        {:ok, run}

      :error ->
        :error
    end
  end

  defp export(event, %Run{} = run, opts) do
    exporter = Config.option(opts, :exporter, [:tracing, :exporter])
    exporter_opts = Config.option(opts, :exporter_opts, [:tracing, :exporter_opts], [])

    cond do
      is_nil(exporter) ->
        :ok

      function_exported?(exporter, :export, 3) ->
        try do
          exporter.export(event, run, exporter_opts)
          :ok
        rescue
          _exception -> :ok
        catch
          _kind, _reason -> :ok
        end

      true ->
        :ok
    end
  end

  defp pop_finished_context(%Run{} = run) do
    case Context.current() do
      %Context{run_id: run_id} when run_id == run.id ->
        if run.parent_id,
          do: restore_parent_context(run),
          else: Context.clear()

      _other ->
        :ok
    end
  end

  defp restore_context(nil), do: Context.clear()
  defp restore_context(%Context{} = context), do: Context.put(context)

  defp run_id(%Run{id: id}), do: id
  defp run_id(id), do: id

  defp context_run_id(%Context{run_id: run_id}), do: run_id
  defp context_run_id(nil), do: nil

  defp context_trace_id(%Context{trace_id: trace_id}), do: trace_id
  defp context_trace_id(nil), do: nil

  defp merge_context_tags(%Context{tags: tags}, child_tags) do
    tags
    |> Kernel.++(List.wrap(child_tags || []))
    |> Enum.map(&to_string/1)
    |> Enum.uniq()
  end

  defp merge_context_tags(nil, child_tags), do: child_tags

  defp merge_context_metadata(%Context{metadata: metadata}, child_metadata) do
    Map.merge(metadata, child_metadata || %{})
  end

  defp merge_context_metadata(nil, child_metadata), do: child_metadata || %{}

  defp restore_parent_context(%Run{} = run) do
    case Store.get(run.parent_id) do
      {:ok, parent} -> Context.put(Context.from_run(parent))
      :error -> Context.put(%Context{run_id: run.parent_id, trace_id: run.trace_id})
    end
  end

  defp normalize_event(event) when is_atom(event), do: event

  defp normalize_event(event) when is_binary(event) do
    event
    |> String.trim()
    |> String.replace(~r/[^A-Za-z0-9_]+/, "_")
    |> String.trim("_")
    |> String.downcase()
  end

  defp normalize_tags(tags), do: tags |> List.wrap() |> Enum.map(&to_string/1)

  defp error_to_map(%{kind: kind, reason: reason}) do
    %{kind: kind, reason: inspect(reason)}
  end

  defp error_to_map(%BeamWeaver.Core.Error{type: type, message: message, details: details}) do
    %{type: type, message: message, details: details}
  end

  defp error_to_map(%exception{} = error) when is_atom(exception) do
    %{type: inspect(exception), message: Exception.message(error)}
  rescue
    _error -> %{type: inspect(exception), message: inspect(error)}
  end

  defp error_to_map(error), do: %{type: "error", message: inspect(error)}

  defp merge_redacted(map, nil), do: map

  defp merge_redacted(map, new_values),
    do: Map.merge(map || %{}, BeamWeaver.Tracing.Redactor.redact(new_values))

  defp timestamp, do: DateTime.utc_now()
end
