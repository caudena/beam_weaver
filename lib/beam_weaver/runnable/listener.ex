defmodule BeamWeaver.Runnable.Listener do
  @moduledoc false

  @behaviour BeamWeaver.Runnable

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Runnable
  alias BeamWeaver.Runnable.Config
  alias BeamWeaver.Tracing
  alias BeamWeaver.Tracing.Run

  defstruct [:runnable, listeners: [], async?: false]

  @impl true
  def invoke(%__MODULE__{} = listener, input, opts) do
    config = Config.normalize(opts)

    with {:ok, run} <- start_run(listener.runnable, input, config),
         :ok <- notify(listener, :on_start, run, config) do
      case Runnable.invoke(listener.runnable, input, Config.to_opts(config)) do
        {:ok, output} ->
          finish(listener, run, output, config)

        {:error, %Error{} = error} ->
          fail(listener, run, error, config)
      end
    end
  end

  @impl true
  def stream(%__MODULE__{} = listener, input, opts) do
    config = Config.normalize(opts)

    with {:ok, run} <- start_run(listener.runnable, input, config),
         :ok <- notify(listener, :on_start, run, config) do
      case Runnable.stream(listener.runnable, input, Config.to_opts(config)) do
        {:ok, stream} ->
          {:ok, finalize_stream(stream, listener, run, config)}

        {:error, %Error{} = error} ->
          fail(listener, run, error, config)
      end
    end
  end

  defp start_run(runnable, input, %Config{} = config) do
    Tracing.start_run(Runnable.name(runnable),
      kind: :runnable,
      inputs: input,
      tags: config.tags,
      metadata: tracing_metadata(config),
      trace_id: config.run_id
    )
  end

  defp tracing_metadata(%Config{} = config) do
    Config.inheritable_metadata(config)
  end

  defp finish(listener, %Run{} = run, output, %Config{} = config) do
    case Tracing.finish_run(run, outputs: output) do
      {:ok, finished} ->
        with :ok <- notify(listener, :on_end, finished, config) do
          {:ok, output}
        end

      :error ->
        {:error, Error.new(:runnable_listener_finish_failed, "listener run could not finish")}
    end
  end

  defp fail(listener, %Run{} = run, %Error{} = error, %Config{} = config) do
    case Tracing.fail_run(run, error) do
      {:ok, failed} ->
        case notify(listener, :on_error, failed, config) do
          :ok -> {:error, error}
          {:error, %Error{} = listener_error} -> {:error, listener_error}
        end

      :error ->
        {:error, error}
    end
  end

  defp finalize_stream(stream, listener, run, config) do
    Stream.transform(
      stream,
      fn -> %{output: nil, seen?: false} end,
      fn item, state ->
        output =
          if state.seen?,
            do: Runnable.Addable.add(state.output, item),
            else: item

        {[item], %{output: output, seen?: true}}
      end,
      fn state ->
        output = if state.seen?, do: state.output, else: []
        finish(listener, run, output, config)
        []
      end
    )
  end

  defp notify(%__MODULE__{listeners: listeners, async?: async?}, event, %Run{} = run, config) do
    case Keyword.get(listeners, event) do
      nil ->
        :ok

      fun when is_function(fun) and async? ->
        Task.async(fn -> call_listener(fun, run, config) end)
        |> Task.await(:infinity)

      fun when is_function(fun) ->
        call_listener(fun, run, config)

      other ->
        {:error,
         Error.new(:invalid_runnable_listener, "listener callback must be a function", %{
           listener: inspect(other)
         })}
    end
  rescue
    exception ->
      {:error,
       Error.new(:runnable_listener_exception, Exception.message(exception), %{
         exception: inspect(exception.__struct__)
       })}
  catch
    kind, reason ->
      {:error,
       Error.new(:runnable_listener_exit, "listener callback exited", %{
         kind: kind,
         reason: inspect(reason)
       })}
  end

  defp call_listener(fun, %Run{} = run, %Config{} = config) when is_function(fun, 2) do
    fun.(run, config)
    |> normalize_listener_result()
  end

  defp call_listener(fun, %Run{} = run, _config) when is_function(fun, 1) do
    fun.(run)
    |> normalize_listener_result()
  end

  defp call_listener(fun, _run, _config) do
    {:error,
     Error.new(
       :invalid_runnable_listener,
       "listener callback must accept one or two arguments",
       %{
         arity: arity(fun)
       }
     )}
  end

  defp normalize_listener_result(:ok), do: :ok
  defp normalize_listener_result({:ok, _value}), do: :ok
  defp normalize_listener_result({:error, %Error{} = error}), do: {:error, error}
  defp normalize_listener_result(_value), do: :ok

  defp arity(fun) when is_function(fun) do
    fun
    |> Function.info(:arity)
    |> elem(1)
  end
end

defimpl BeamWeaver.Runnable.Introspect, for: BeamWeaver.Runnable.Listener do
  def graph(%{runnable: runnable}, opts), do: BeamWeaver.Runnable.Introspect.graph(runnable, opts)
  def input_schema(%{runnable: runnable}), do: BeamWeaver.Runnable.input_schema(runnable)
  def output_schema(%{runnable: runnable}), do: BeamWeaver.Runnable.output_schema(runnable)
  def config_specs(%{runnable: runnable}), do: BeamWeaver.Runnable.config_specs(runnable)
end
