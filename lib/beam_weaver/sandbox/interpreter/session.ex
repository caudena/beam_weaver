defmodule BeamWeaver.Sandbox.Interpreter.Session do
  @moduledoc """
  Supervised process wrapper for explicit interpreter adapters.
  """

  use GenServer

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Sandbox.Interpreter.Snapshot
  alias BeamWeaver.Telemetry
  alias BeamWeaver.Tracing.Redactor

  defstruct [
    :adapter,
    :adapter_state,
    timeout: 30_000,
    max_snapshot_bytes: 1_000_000,
    metadata: %{}
  ]

  @type t :: pid()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @spec start(keyword()) :: GenServer.on_start()
  def start(opts) do
    GenServer.start(__MODULE__, opts)
  end

  @spec eval(t(), String.t(), keyword()) :: {:ok, term()} | {:error, Error.t()}
  def eval(pid, code, opts \\ []) when is_pid(pid) and is_binary(code) do
    GenServer.call(pid, {:eval, code, opts}, call_timeout(pid, opts))
  end

  @spec snapshot(t(), keyword()) :: {:ok, Snapshot.t()} | {:error, Error.t()}
  def snapshot(pid, opts \\ []) when is_pid(pid) do
    GenServer.call(pid, {:snapshot, opts}, call_timeout(pid, opts))
  end

  @spec restore(t(), Snapshot.t(), keyword()) :: :ok | {:error, Error.t()}
  def restore(pid, %Snapshot{} = snapshot, opts \\ []) when is_pid(pid) do
    GenServer.call(pid, {:restore, snapshot, opts}, call_timeout(pid, opts))
  end

  @spec close(t(), keyword()) :: :ok
  def close(pid, opts \\ []) when is_pid(pid) do
    GenServer.call(pid, {:close, opts}, call_timeout(pid, opts))
  catch
    :exit, _reason -> :ok
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    with {:ok, adapter} <- fetch_adapter(opts),
         :ok <- validate_adapter(adapter),
         {:ok, adapter_state} <- open_adapter(adapter, opts) do
      {:ok,
       %__MODULE__{
         adapter: adapter,
         adapter_state: adapter_state,
         timeout: Keyword.get(opts, :timeout, 30_000),
         max_snapshot_bytes: Keyword.get(opts, :max_snapshot_bytes, 1_000_000),
         metadata: Redactor.redact(Keyword.get(opts, :metadata, %{}))
       }}
    else
      {:error, %Error{} = error} -> {:stop, error}
    end
  end

  @impl true
  def handle_call({:eval, code, opts}, _from, state) do
    timeout = Keyword.get(opts, :timeout, state.timeout)

    case timed_call(state, :eval, timeout, fn ->
           state.adapter.eval(state.adapter_state, code, opts)
         end) do
      {:ok, result} ->
        case normalize_eval(result, state.adapter_state) do
          {:ok, value, adapter_state} ->
            {:reply, {:ok, value}, %{state | adapter_state: adapter_state}}

          {:error, %Error{} = error, adapter_state} ->
            {:reply, {:error, error}, %{state | adapter_state: adapter_state}}
        end

      {:error, %Error{} = error} ->
        {:reply, {:error, error}, state}
    end
  end

  def handle_call({:snapshot, opts}, _from, state) do
    if function_exported?(state.adapter, :snapshot, 2) do
      timeout = Keyword.get(opts, :timeout, state.timeout)

      case timed_call(state, :snapshot, timeout, fn -> state.adapter.snapshot(state.adapter_state, opts) end) do
        {:ok, result} ->
          case normalize_snapshot(result, state) do
            {:ok, %Snapshot{} = snapshot} -> {:reply, {:ok, snapshot}, state}
            {:error, %Error{} = error} -> {:reply, {:error, error}, state}
          end

        {:error, %Error{} = error} ->
          {:reply, {:error, error}, state}
      end
    else
      {:reply, {:error, Error.new(:interpreter_snapshot_unsupported, "interpreter adapter does not support snapshots")},
       state}
    end
  end

  def handle_call({:restore, %Snapshot{} = snapshot, opts}, _from, state) do
    cond do
      snapshot.adapter != state.adapter ->
        {:reply,
         {:error,
          Error.new(:interpreter_snapshot_adapter_mismatch, "interpreter snapshot belongs to a different adapter", %{
            expected: state.adapter,
            actual: snapshot.adapter
          })}, state}

      not function_exported?(state.adapter, :restore, 2) ->
        {:reply, {:error, Error.new(:interpreter_restore_unsupported, "interpreter adapter does not support restore")},
         state}

      true ->
        timeout = Keyword.get(opts, :timeout, state.timeout)

        case timed_call(state, :restore, timeout, fn -> state.adapter.restore(snapshot.data, opts) end) do
          {:ok, result} ->
            case normalize_restore(result) do
              {:ok, adapter_state} -> {:reply, :ok, %{state | adapter_state: adapter_state}}
              {:error, %Error{} = error} -> {:reply, {:error, error}, state}
            end

          {:error, %Error{} = error} ->
            {:reply, {:error, error}, state}
        end
    end
  end

  def handle_call({:close, opts}, _from, state) do
    state = close_adapter(state, opts)
    {:stop, :normal, :ok, state}
  end

  def handle_call(:timeout, _from, state), do: {:reply, state.timeout, state}

  @impl true
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    close_adapter(state, [])
    :ok
  end

  defp fetch_adapter(opts) do
    case Keyword.get(opts, :adapter) do
      adapter when is_atom(adapter) ->
        {:ok, adapter}

      _other ->
        {:error, Error.new(:invalid_interpreter_adapter, "interpreter adapter module is required")}
    end
  end

  defp validate_adapter(adapter) do
    cond do
      not Code.ensure_loaded?(adapter) ->
        {:error,
         Error.new(:invalid_interpreter_adapter, "interpreter adapter could not be loaded", %{
           adapter: adapter
         })}

      not function_exported?(adapter, :open, 1) ->
        {:error, Error.new(:invalid_interpreter_adapter, "interpreter adapter must implement open/1")}

      not function_exported?(adapter, :eval, 3) ->
        {:error, Error.new(:invalid_interpreter_adapter, "interpreter adapter must implement eval/3")}

      true ->
        :ok
    end
  end

  defp open_adapter(adapter, opts) do
    case adapter.open(opts) do
      {:ok, state} -> {:ok, state}
      {:error, %Error{} = error} -> {:error, error}
      state -> {:ok, state}
    end
  rescue
    exception ->
      {:error,
       Error.new(:interpreter_open_failed, "interpreter adapter failed to open", %{
         adapter: adapter,
         error: Exception.message(exception)
       })}
  end

  defp timed_call(state, operation, timeout, fun) do
    metadata = operation_metadata(state, operation, timeout)
    start = System.monotonic_time()

    Telemetry.emit(
      [:beam_weaver, :sandbox, :interpreter, operation, :start],
      %{system_time: System.system_time()},
      metadata
    )

    task = Task.async(fn -> safe_adapter_call(fun) end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, result}} ->
        Telemetry.emit(
          [:beam_weaver, :sandbox, :interpreter, operation, :stop],
          %{duration: System.monotonic_time() - start},
          metadata
        )

        {:ok, result}

      {:ok, {:exception, exception}} ->
        Telemetry.emit(
          [:beam_weaver, :sandbox, :interpreter, operation, :exception],
          %{duration: System.monotonic_time() - start},
          Map.put(metadata, :error, Exception.message(exception))
        )

        {:error,
         Error.new(:interpreter_execution_failed, "interpreter operation failed", %{
           operation: operation,
           reason: Exception.message(exception)
         })}

      {:ok, {:throw, kind, reason}} ->
        Telemetry.emit(
          [:beam_weaver, :sandbox, :interpreter, operation, :exception],
          %{duration: System.monotonic_time() - start},
          metadata |> Map.put(:kind, kind) |> Map.put(:reason, inspect(reason))
        )

        {:error,
         Error.new(:interpreter_execution_failed, "interpreter operation failed", %{
           operation: operation,
           kind: kind,
           reason: inspect(reason)
         })}

      nil ->
        Telemetry.emit(
          [:beam_weaver, :sandbox, :interpreter, operation, :timeout],
          %{duration: System.monotonic_time() - start},
          metadata
        )

        {:error,
         Error.new(:interpreter_timeout, "interpreter operation timed out", %{
           operation: operation,
           timeout_ms: timeout
         })}

      {:exit, reason} ->
        Telemetry.emit(
          [:beam_weaver, :sandbox, :interpreter, operation, :exception],
          %{duration: System.monotonic_time() - start},
          Map.put(metadata, :reason, inspect(reason))
        )

        {:error,
         Error.new(:interpreter_execution_failed, "interpreter operation failed", %{
           operation: operation,
           reason: inspect(reason)
         })}
    end
  end

  defp safe_adapter_call(fun) do
    {:ok, fun.()}
  rescue
    exception -> {:exception, exception}
  catch
    kind, reason -> {:throw, kind, reason}
  end

  defp normalize_eval({:ok, value, adapter_state}, _previous_state), do: {:ok, value, adapter_state}
  defp normalize_eval({:ok, value}, previous_state), do: {:ok, value, previous_state}

  defp normalize_eval({:error, %Error{} = error, adapter_state}, _previous_state),
    do: {:error, error, adapter_state}

  defp normalize_eval({:error, %Error{} = error}, previous_state), do: {:error, error, previous_state}
  defp normalize_eval(value, previous_state), do: {:ok, value, previous_state}

  defp normalize_snapshot({:ok, data}, state), do: build_snapshot(data, %{}, state)
  defp normalize_snapshot({:ok, data, metadata}, state), do: build_snapshot(data, metadata, state)
  defp normalize_snapshot({:error, %Error{} = error}, _state), do: {:error, error}
  defp normalize_snapshot(data, state), do: build_snapshot(data, %{}, state)

  defp build_snapshot(data, metadata, state) do
    size = data |> :erlang.term_to_binary() |> byte_size()

    if size > state.max_snapshot_bytes do
      {:error,
       Error.new(:interpreter_snapshot_too_large, "interpreter snapshot exceeds configured limit", %{
         size_bytes: size,
         max_snapshot_bytes: state.max_snapshot_bytes
       })}
    else
      {:ok,
       %Snapshot{
         adapter: state.adapter,
         data: data,
         size_bytes: size,
         metadata: Redactor.redact(metadata || %{})
       }}
    end
  end

  defp normalize_restore({:ok, adapter_state}), do: {:ok, adapter_state}
  defp normalize_restore({:error, %Error{} = error}), do: {:error, error}
  defp normalize_restore(adapter_state), do: {:ok, adapter_state}

  defp close_adapter(%__MODULE__{adapter_state: nil} = state, _opts), do: state

  defp close_adapter(%__MODULE__{adapter: adapter, adapter_state: adapter_state} = state, opts) do
    if function_exported?(adapter, :close, 2) do
      adapter.close(adapter_state, opts)
    else
      :ok
    end

    %{state | adapter_state: nil}
  rescue
    _exception -> %{state | adapter_state: nil}
  end

  defp operation_metadata(state, operation, timeout) do
    %{
      adapter: state.adapter,
      operation: operation,
      timeout_ms: timeout,
      metadata: state.metadata
    }
    |> Redactor.redact()
  end

  defp call_timeout(pid, opts) do
    timeout =
      case Keyword.get(opts, :timeout) do
        nil -> GenServer.call(pid, :timeout, :infinity)
        timeout -> timeout
      end

    case timeout do
      nil -> :infinity
      :infinity -> :infinity
      timeout when is_integer(timeout) -> timeout + 1_000
    end
  catch
    :exit, _reason -> :infinity
  end
end
