defmodule BeamWeaver.Tracing do
  @moduledoc """
  Local run trees, context propagation, redaction, and exporter boundaries.

  Runs are kept in memory on the node, so `get_run/1` and `get_tree/1` can
  read them. Running runs always stay; once more runs are stored than
  `config :beam_weaver, :tracing, max_runs:` allows (10,000 by default), the
  runs that finished first are dropped. `max_runs: 0` keeps only the runs
  still in progress, for nodes that only export. `clear/0` drops them all.

  A run belongs to the process that started it. When that process exits
  before the run finishes, as a node or tool task killed at its timeout does,
  the stored run gets `status: :error` and `error: %{kind: :exit, reason: ...}`,
  so `max_runs:` counts it as finished, and the exporter the run started with
  gets its `:error` event, sent from another process.
  """

  alias BeamWeaver.Config
  alias BeamWeaver.Tracing.Context
  alias BeamWeaver.Tracing.Exporter
  alias BeamWeaver.Tracing.Run
  alias BeamWeaver.Tracing.Store

  @type run_ref :: Run.t() | Run.id()
  @weave_scope_queue BeamWeaver.Tracing.Exporters.WeaveScope.Queue

  @doc false
  def configured_exporter do
    case Config.get([:tracing, :exporter]) do
      nil -> default_exporter()
      exporter -> exporter
    end
  end

  @doc false
  def exporter_configured?, do: not is_nil(configured_exporter())

  @doc """
  Starts a trace run and makes it the current process context.
  """
  @spec start_run(String.t() | atom(), keyword()) :: {:ok, Run.t()}
  def start_run(name, opts \\ []) do
    parent_context = Context.current()
    parent_id = Keyword.get(opts, :parent_id) || context_run_id(parent_context)
    trace_id = Keyword.get(opts, :trace_id) || context_trace_id(parent_context)
    run_metadata = merge_context_metadata(parent_context, Keyword.get(opts, :metadata, %{}))

    context_metadata =
      case Keyword.fetch(opts, :context_metadata) do
        {:ok, metadata} -> merge_context_metadata(parent_context, metadata)
        :error -> run_metadata
      end

    run_opts =
      opts
      |> Keyword.put(:parent_id, parent_id)
      |> Keyword.put(:trace_id, trace_id)
      |> Keyword.put(:tags, merge_context_tags(parent_context, Keyword.get(opts, :tags, [])))
      |> Keyword.put(:metadata, run_metadata)
      |> Keyword.put(:context_metadata, context_metadata)

    run = Run.new(name, run_opts)
    exporter = exporter(opts)

    :ok = Store.put(run, exporter)
    export_event(:started, run, exporter)
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

  Use it to group several steps under one parent run. It records a normal trace
  run with `kind: :chain` and makes it the current process context, so runs
  started inside `fun` become its children without passing the run around.
  """
  @spec with_chain_group(String.t() | atom(), keyword(), (-> term())) :: term()
  def with_chain_group(name, opts \\ [], fun) when is_function(fun, 0) do
    with_run(name, Keyword.put_new(opts, :kind, :chain), fun)
  end

  @doc """
  Emits a custom tracing event through `:telemetry` with the current trace context.

  To receive these events, attach a `:telemetry` handler to
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
  Starts a task that runs `fun` with the caller's trace context attached.

  ## Options

    * `:supervisor` - start an unlinked task under this `Task.Supervisor`
      instead of a task linked to the caller
    * `:context` - trace context to attach instead of the caller's current one
    * `:shutdown` - shutdown option for supervised tasks
  """
  @spec async((-> term()), keyword()) :: Task.t()
  def async(fun, opts \\ []) when is_function(fun, 0) do
    context = Keyword.get_lazy(opts, :context, &capture_context/0)
    fun = fn -> attach_context(context, fun) end

    case Keyword.get(opts, :supervisor) do
      nil -> Task.async(fun)
      supervisor -> Task.Supervisor.async_nolink(supervisor, fun, Keyword.take(opts, [:shutdown]))
    end
  end

  @doc """
  Returns a stored run, or `:error` once it was dropped from the store.
  """
  @spec get_run(Run.id()) :: {:ok, Run.t()} | :error
  defdelegate get_run(run_id), to: Store, as: :get

  @doc """
  Returns a run with nested child runs, as `%{run: run, children: [tree]}`.

  Child runs that were already dropped from the store are missing.
  """
  @spec get_tree(Run.id()) :: {:ok, map()} | :error
  defdelegate get_tree(run_id), to: Store, as: :tree

  @doc """
  Drops every run from the local store.

  Runs in progress are dropped too: finishing one afterwards returns `:error`
  and exports nothing.
  """
  @spec clear() :: :ok
  defdelegate clear(), to: Store

  @doc """
  Flushes the configured tracing exporter when it supports explicit draining.

  This is useful for short-lived scripts that exit immediately after a run
  completes. Long-lived applications can rely on the supervised exporter queue.
  """
  @spec flush_exporter(timeout()) :: :ok | {:error, term()}
  def flush_exporter(timeout \\ 60_000) when is_integer(timeout) and timeout > 0 do
    exporter = configured_exporter()
    exporter_opts = Config.get([:tracing, :exporter_opts], [])

    cond do
      is_nil(exporter) ->
        :ok

      exporter == @weave_scope_queue ->
        queue =
          Keyword.get(exporter_opts, :queue, @weave_scope_queue)

        BeamWeaver.Tracing.Exporters.WeaveScope.Queue.flush(queue, timeout)

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
        export_event(event, run, exporter(opts))
        pop_finished_context(run)
        {:ok, run}

      :error ->
        :error
    end
  end

  # The exporter of a call's `:exporter` option, or the configured one, with
  # its options; `nil` when nothing exports.
  defp exporter(opts) do
    case exporter_option(opts) do
      nil -> nil
      exporter -> {exporter, Config.option(opts, :exporter_opts, [:tracing, :exporter_opts], [])}
    end
  end

  @doc false
  # Sends one event to an exporter. An exporter that raises, or whose module
  # has no `export/3`, never breaks the run. The module is loaded first: an
  # exporter named only in config isn't loaded until something calls it.
  @spec export_event(Exporter.event(), Run.t(), {module(), keyword()} | nil) :: :ok
  def export_event(_event, %Run{}, nil), do: :ok

  def export_event(event, %Run{} = run, {exporter, exporter_opts}) do
    if Code.ensure_loaded?(exporter) and function_exported?(exporter, :export, 3) do
      try do
        exporter.export(event, run, exporter_opts)
      rescue
        _exception -> :ok
      catch
        _kind, _reason -> :ok
      end
    end

    :ok
  end

  defp exporter_option(opts) do
    if Keyword.has_key?(opts, :exporter) do
      Keyword.fetch!(opts, :exporter)
    else
      configured_exporter()
    end
  end

  defp default_exporter do
    if weavescope_configured?(), do: @weave_scope_queue
  end

  defp weavescope_configured? do
    not is_nil(Config.get([:weave_scope, :api_key])) and
      not is_nil(Config.get([:weave_scope, :endpoint]))
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
