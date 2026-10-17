defmodule BeamWeaver.Runnable.Runtime do
  @moduledoc false

  alias BeamWeaver.Core.ChatModel
  alias BeamWeaver.Core.DecisionModel
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Result
  alias BeamWeaver.Runnable.Config

  # Runnable options that configure the run itself. A chat model step gets the
  # rest, such as `temperature:`; `metadata:` would otherwise reach providers
  # that send it with the request.
  @run_config_keys [
    :config,
    :tags,
    :metadata,
    :run_name,
    :run_id,
    :max_concurrency,
    :recursion_limit,
    :configurable,
    :context,
    :task_supervisor
  ]

  def name(%{name: name}) when (is_binary(name) or is_atom(name)) and not is_nil(name),
    do: to_string(name)

  def name(%{__struct__: module}), do: inspect(module)
  def name(module) when is_atom(module), do: inspect(module)
  def name(fun) when is_function(fun), do: "function"
  def name(other), do: inspect(other)

  def invoke(runnable, input, opts) do
    config = Config.normalize(opts)
    emit(:start, %{system_time: System.system_time()}, metadata(runnable, config))

    started = System.monotonic_time()

    result =
      runnable
      |> coerce()
      |> do_invoke(input, Config.to_opts(config))
      |> normalize_result()

    duration = System.monotonic_time() - started

    case result do
      {:ok, output} ->
        emit(:stop, %{duration: duration}, metadata(runnable, config))
        {:ok, output}

      {:error, %Error{} = error} ->
        emit(
          :exception,
          %{duration: duration},
          Map.put(metadata(runnable, config), :error, error)
        )

        {:error, error}
    end
  end

  def batch(runnable, inputs, opts) when is_list(inputs) do
    runnable = coerce(runnable)
    config = Config.normalize(opts)

    result =
      if runnable_impl?(runnable, :batch, 3) do
        runnable.__struct__.batch(runnable, inputs, Config.to_opts(config))
      else
        default_batch(runnable, inputs, Config.to_opts(config), config.max_concurrency)
      end

    normalize_result(result)
  rescue
    exception -> {:error, exception_error(:runnable_batch_exception, exception)}
  end

  def batch(_runnable, _inputs, _opts),
    do: {:error, Error.new(:invalid_runnable_input, "batch input must be a list")}

  def stream(runnable, input, opts) do
    runnable = coerce(runnable)
    config = Config.normalize(opts)

    BeamWeaver.Stream.emit(
      :start,
      %{system_time: System.system_time()},
      metadata(runnable, config)
    )

    emit(:stream_start, %{system_time: System.system_time()}, metadata(runnable, config))

    result =
      cond do
        chat_model?(runnable) ->
          ChatModel.stream(runnable, input, chat_model_opts(Config.to_opts(config)))

        runnable_impl?(runnable, :stream, 3) ->
          runnable.__struct__.stream(runnable, input, Config.to_opts(config))

        true ->
          with {:ok, output} <- invoke(runnable, input, Config.to_opts(config)), do: {:ok, [output]}
      end

    case normalize_stream_result(result) do
      {:ok, stream} ->
        emit(:stream_stop, %{count: :unknown}, metadata(runnable, config))
        {:ok, instrument_stream(stream, runnable, config)}

      {:error, %Error{} = error} ->
        emit(:stream_exception, %{count: 0}, Map.put(metadata(runnable, config), :error, error))

        BeamWeaver.Stream.emit(
          :exception,
          %{count: 0},
          Map.put(metadata(runnable, config), :error, error)
        )

        {:error, error}
    end
  rescue
    exception -> {:error, exception_error(:runnable_stream_exception, exception)}
  end

  def transform(runnable, input, opts) do
    runnable = coerce(runnable)
    config = Config.normalize(opts)

    result =
      cond do
        runnable_impl?(runnable, :transform, 3) ->
          runnable.__struct__.transform(runnable, input, Config.to_opts(config))

        Enumerable.impl_for(input) ->
          input
          |> Enum.reduce(nil, fn item, acc ->
            if is_nil(acc), do: item, else: BeamWeaver.Runnable.Addable.add(acc, item)
          end)
          |> then(&stream(runnable, &1, Config.to_opts(config)))

        true ->
          {:error, Error.new(:invalid_runnable_input, "transform input must be Enumerable")}
      end

    normalize_stream_result(result)
  rescue
    exception -> {:error, exception_error(:runnable_transform_exception, exception)}
  end

  defp coerce(%{__struct__: _module} = runnable), do: runnable
  defp coerce(fun) when is_function(fun), do: %BeamWeaver.Runnable.Lambda{fun: fun}
  defp coerce(module) when is_atom(module), do: module

  defp coerce(other) do
    %BeamWeaver.Runnable.Lambda{
      fun: fn _input ->
        {:error,
         Error.new(:invalid_runnable, "value cannot be used as a runnable", %{
           runnable: inspect(other)
         })}
      end
    }
  end

  defp do_invoke(%{__struct__: module} = runnable, input, opts) do
    cond do
      # A chat model's own `invoke/3` takes a message list; `ChatModel.invoke/3`
      # also accepts a string or a formatted prompt.
      chat_model?(runnable) -> ChatModel.invoke(runnable, input, chat_model_opts(opts))
      exported?(module, :invoke, 3) -> module.invoke(runnable, input, opts)
      exported?(module, :invoke, 2) -> module.invoke(runnable, input)
      true -> {:error, Error.new(:invalid_runnable, "runnable struct must implement invoke/3")}
    end
  rescue
    exception -> {:error, exception_error(:runnable_exception, exception)}
  catch
    kind, reason ->
      {:error,
       Error.new(:runnable_exit, "runnable exited before returning", %{
         kind: kind,
         reason: inspect(reason)
       })}
  end

  defp do_invoke(module, input, opts) when is_atom(module) do
    cond do
      exported?(module, :invoke, 2) ->
        module.invoke(input, opts)

      exported?(module, :invoke, 1) ->
        module.invoke(input)

      true ->
        {:error, Error.new(:invalid_runnable, "runnable module must implement invoke/1 or invoke/2")}
    end
  end

  defp default_batch(runnable, inputs, opts, max_concurrency) do
    context = BeamWeaver.Tracing.capture_context()

    inputs
    |> Task.async_stream(
      fn input -> BeamWeaver.Tracing.attach_context(context, fn -> invoke(runnable, input, opts) end) end,
      ordered: true,
      max_concurrency: max_concurrency,
      timeout: Keyword.get(opts, :timeout, 300_000),
      on_timeout: :kill_task
    )
    |> Stream.map(fn
      {:ok, result} ->
        result

      {:exit, reason} ->
        {:error, Error.new(:runnable_batch_exit, "batch task exited", %{reason: inspect(reason)})}
    end)
    |> Result.collect()
  end

  defp normalize_result({:ok, _value} = result), do: result
  defp normalize_result({:error, %Error{}} = result), do: result

  defp normalize_result({:error, reason}),
    do: {:error, Error.new(:runnable_error, "runnable returned an error", %{reason: inspect(reason)})}

  defp normalize_result(value), do: {:ok, value}

  defp normalize_stream_result({:ok, stream}) do
    if Enumerable.impl_for(stream),
      do: {:ok, stream},
      else: {:error, Error.new(:invalid_runnable_stream, "stream result must be Enumerable")}
  end

  defp normalize_stream_result({:error, %Error{}} = result), do: result

  defp normalize_stream_result({:error, reason}),
    do: {:error, Error.new(:runnable_error, "runnable stream returned an error", %{reason: inspect(reason)})}

  defp normalize_stream_result(stream), do: normalize_stream_result({:ok, stream})

  defp instrument_stream(stream, runnable, config) do
    metadata = metadata(runnable, config)

    Stream.transform(
      stream,
      fn -> 0 end,
      fn item, count ->
        BeamWeaver.Stream.emit(:event, %{count: 1}, metadata)
        {[item], count + 1}
      end,
      fn count ->
        BeamWeaver.Stream.emit(:stop, %{count: count}, metadata)
      end
    )
  end

  defp runnable_impl?(%{__struct__: module}, callback, arity),
    do: exported?(module, callback, arity)

  defp runnable_impl?(_runnable, _callback, _arity), do: false

  # Model wrappers such as `Models.cached/3` implement the chat model behaviour
  # also when they wrap a decision model, which takes a map instead.
  defp chat_model?(%{__struct__: module} = runnable),
    do: BeamWeaver.Behaviour.implemented_by?(module, ChatModel) and not DecisionModel.model?(runnable)

  defp chat_model?(_runnable), do: false

  defp chat_model_opts(opts), do: Keyword.drop(opts, @run_config_keys)

  defp exported?(module, function, arity) when is_atom(module) do
    Code.ensure_loaded?(module) and function_exported?(module, function, arity)
  end

  defp metadata(runnable, %Config{} = config) do
    %{
      runnable: runnable_name(runnable, config),
      run_name: config.run_name,
      run_id: config.run_id,
      tags: config.tags,
      metadata: config.metadata
    }
  end

  defp runnable_name(_runnable, %Config{run_name: run_name})
       when (is_binary(run_name) or is_atom(run_name)) and not is_nil(run_name),
       do: to_string(run_name)

  defp runnable_name(runnable, _config), do: name(runnable)

  defp emit(event, measurements, metadata) do
    if Code.ensure_loaded?(:telemetry) do
      :telemetry.execute([:beam_weaver, :runnable, event], measurements, metadata)
    end
  end

  defp exception_error(type, exception) do
    Error.new(type, Exception.message(exception), %{exception: inspect(exception.__struct__)})
  end
end
