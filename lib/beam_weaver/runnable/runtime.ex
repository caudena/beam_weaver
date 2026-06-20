defmodule BeamWeaver.Runnable.Runtime do
  @moduledoc false

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Result
  alias BeamWeaver.Runnable.Config

  def name(%{name: name}) when (is_binary(name) or is_atom(name)) and not is_nil(name),
    do: to_string(name)

  def name(%BeamWeaver.Runnable.Listener{runnable: runnable}), do: name(runnable)

  def name(%{__struct__: module}), do: inspect(module)
  def name(module) when is_atom(module), do: inspect(module)
  def name(fun) when is_function(fun), do: "function"
  def name(other), do: inspect(other)

  def invoke(runnable, input, opts \\ []) do
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

  def batch(runnable, inputs, opts \\ [])

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

  def batch_as_completed(runnable, inputs, opts \\ [])

  def batch_as_completed(runnable, inputs, opts) when is_list(inputs) do
    runnable = coerce(runnable)
    config = Config.normalize(opts)
    call_opts = Config.to_opts(config)
    max_concurrency = config.max_concurrency
    timeout = Keyword.get(call_opts, :timeout, 300_000)

    stream =
      inputs
      |> Enum.with_index()
      |> Task.async_stream(
        fn {input, index} ->
          {index, invoke(runnable, input, call_opts)}
        end,
        ordered: false,
        max_concurrency: max_concurrency,
        timeout: timeout,
        on_timeout: :kill_task
      )
      |> Stream.map(fn
        {:ok, {index, {:ok, output}}} ->
          {index, {:ok, output}}

        {:ok, {index, {:error, %Error{} = error}}} ->
          {index, {:error, error}}

        {:exit, reason} ->
          {:unknown, {:error, Error.new(:runnable_batch_exit, "batch task exited", %{reason: inspect(reason)})}}
      end)

    {:ok, stream}
  rescue
    exception -> {:error, exception_error(:runnable_batch_exception, exception)}
  end

  def batch_as_completed(_runnable, _inputs, _opts),
    do: {:error, Error.new(:invalid_runnable_input, "batch input must be a list")}

  def stream(runnable, input, opts \\ []) do
    runnable = coerce(runnable)
    config = Config.normalize(opts)

    BeamWeaver.Stream.emit(
      :start,
      %{system_time: System.system_time()},
      metadata(runnable, config)
    )

    emit(:stream_start, %{system_time: System.system_time()}, metadata(runnable, config))

    result =
      if runnable_impl?(runnable, :stream, 3) do
        runnable.__struct__.stream(runnable, input, Config.to_opts(config))
      else
        case invoke(runnable, input, Config.to_opts(config)) do
          {:ok, output} -> {:ok, [output]}
          {:error, %Error{} = error} -> {:error, error}
        end
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

  def transform(runnable, input, opts \\ []) do
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

  def stream_events(runnable, input, opts \\ []) do
    runnable = coerce(runnable)
    config = Config.normalize(opts)
    metadata = metadata(runnable, config)

    case stream(runnable, input, Config.to_opts(config)) do
      {:ok, stream} ->
        envelope_opts = [
          run_id: config.run_id,
          node: metadata.runnable,
          metadata: metadata
        ]

        start =
          BeamWeaver.Stream.envelope(
            BeamWeaver.Stream.event(:debug, %{kind: :start}),
            envelope_opts
          )

        done =
          BeamWeaver.Stream.envelope(
            BeamWeaver.Stream.event(:done, %{result: nil}),
            envelope_opts
          )

        events =
          stream
          |> Stream.map(&BeamWeaver.Stream.envelope(&1, envelope_opts))
          |> then(&Stream.concat([[start], &1, [done]]))
          |> filter_stream_events(opts)

        {:ok, events}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  def stream_log(runnable, input, opts \\ []) do
    runnable = coerce(runnable)
    config = Config.normalize(opts)

    with {:ok, stream} <- stream(runnable, input, Config.to_opts(config)) do
      output = Enum.to_list(stream)
      final = BeamWeaver.Stream.Finalize.finalize(output)
      id = config.run_id

      patches =
        [
          %BeamWeaver.Runnable.RunLogPatch{
            ops: [
              %{
                "op" => "replace",
                "path" => "",
                "value" => %BeamWeaver.Runnable.RunLog{
                  id: id,
                  streamed_output: [],
                  final_output: nil,
                  logs: %{}
                }
              }
            ]
          }
        ] ++
          Enum.map(output, fn item ->
            %BeamWeaver.Runnable.RunLogPatch{
              ops: [%{"op" => "add", "path" => "/streamed_output/-", "value" => item}]
            }
          end) ++
          [
            %BeamWeaver.Runnable.RunLogPatch{
              ops: [%{"op" => "replace", "path" => "/final_output", "value" => final}]
            }
          ]

      {:ok, patches}
    end
  end

  def coerce(%{__struct__: _module} = runnable), do: runnable
  def coerce(fun) when is_function(fun), do: %BeamWeaver.Runnable.Lambda{fun: fun}
  def coerce(module) when is_atom(module), do: module

  def coerce(other) do
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
    inputs
    |> Task.async_stream(&invoke(runnable, &1, opts),
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

  defp filter_stream_events(events, opts) do
    filters = %{
      include_names: normalized_filter_values(Keyword.get(opts, :include_names, [])),
      exclude_names: normalized_filter_values(Keyword.get(opts, :exclude_names, [])),
      include_tags: normalized_filter_values(Keyword.get(opts, :include_tags, [])),
      exclude_tags: normalized_filter_values(Keyword.get(opts, :exclude_tags, []))
    }

    Stream.filter(events, &event_visible?(&1, filters))
  end

  defp event_visible?(%BeamWeaver.Stream.Envelope{} = event, filters) do
    name = normalize_filter_value(event.node)
    tags = event.metadata |> Map.get(:tags, []) |> Enum.map(&normalize_filter_value/1)

    included_by_name? =
      filters.include_names == [] or name in filters.include_names

    included_by_tag? =
      filters.include_tags == [] or Enum.any?(tags, &(&1 in filters.include_tags))

    excluded_by_name? = name in filters.exclude_names
    excluded_by_tag? = Enum.any?(tags, &(&1 in filters.exclude_tags))

    included_by_name? and included_by_tag? and not excluded_by_name? and not excluded_by_tag?
  end

  defp normalized_filter_values(values) do
    values
    |> List.wrap()
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&normalize_filter_value/1)
  end

  defp normalize_filter_value(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_filter_value(value) when is_binary(value), do: value
  defp normalize_filter_value(value), do: to_string(value)

  defp exception_error(type, exception) do
    Error.new(type, Exception.message(exception), %{exception: inspect(exception.__struct__)})
  end
end
