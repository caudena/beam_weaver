defmodule BeamWeaver.Graph.Compiled.Runtime do
  @moduledoc false

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Graph.Command
  alias BeamWeaver.Graph.Execution.CommandRouter
  alias BeamWeaver.Graph.Execution.Runner
  alias BeamWeaver.Graph.Execution.Stream, as: ExecutionStream
  alias BeamWeaver.Graph.Execution.SubgraphRouter
  alias BeamWeaver.Stream, as: BWStream

  def invoke(compiled, %Command{} = command, opts) do
    opts =
      command
      |> CommandRouter.command_opts(opts, false)
      |> rebase_time_travel_opts(compiled)

    case Runner.execute(
           compiled,
           graph_input(compiled, CommandRouter.command_update(command)),
           opts
         ) do
      {:ok, result, _events} -> {:ok, graph_output(compiled, result)}
      {:interrupted, interrupt, _events} -> {:interrupted, interrupt}
      {:parent_command, command, _events} -> CommandRouter.parent_command_error(command)
      {:error, error, _events} -> {:error, error}
    end
  end

  def invoke(compiled, input, opts) when is_map(input) do
    opts =
      opts
      |> Keyword.put(:collect_stream?, false)
      |> rebase_time_travel_opts(compiled)

    case Runner.execute(
           compiled,
           graph_input(compiled, CommandRouter.normalize_update(input)),
           opts
         ) do
      {:ok, result, _events} -> {:ok, graph_output(compiled, result)}
      {:interrupted, interrupt, _events} -> {:interrupted, interrupt}
      {:parent_command, command, _events} -> CommandRouter.parent_command_error(command)
      {:error, error, _events} -> {:error, error}
    end
  end

  def invoke(_compiled, _input, _opts),
    do: {:error, Error.new(:invalid_input, "graph input must be a map")}

  def stream(compiled, %Command{} = command, opts) do
    command_opts =
      command
      |> CommandRouter.command_opts(opts, true)
      |> rebase_time_travel_opts(compiled)

    input = graph_input(compiled, CommandRouter.command_update(command))
    do_stream(compiled, input, command_opts, Keyword.get(opts, :live, false))
  end

  def stream(compiled, input, opts) when is_map(input) do
    stream_opts =
      opts
      |> Keyword.put(:collect_stream?, true)
      |> rebase_time_travel_opts(compiled)

    input = graph_input(compiled, CommandRouter.normalize_update(input))
    do_stream(compiled, input, stream_opts, Keyword.get(opts, :live, false))
  end

  def stream(_compiled, _input, _opts),
    do: {:error, Error.new(:invalid_input, "graph input must be a map")}

  def stream_events(compiled, input, opts) do
    opts = Keyword.put(opts, :stream_mode, :events)

    if Keyword.get(opts, :live, false) do
      stream(compiled, input, opts)
    else
      case stream(compiled, input, opts) do
        {:ok, events} ->
          {:ok, lifecycle_events(compiled, events, opts, :ok)}

        {:interrupted, %{events: events} = interrupt} ->
          {:interrupted, Map.put(interrupt, :events, lifecycle_events(compiled, events, opts, :interrupted))}

        other ->
          other
      end
    end
  end

  def resume(compiled, resume, opts) do
    opts =
      opts
      |> Keyword.put(:resume, resume)
      |> Keyword.put(:collect_stream?, false)
      |> rebase_time_travel_opts(compiled)

    case Runner.execute(compiled, %{}, opts) do
      {:ok, result, _events} -> {:ok, result}
      {:interrupted, interrupt, _events} -> {:interrupted, interrupt}
      {:parent_command, command, _events} -> CommandRouter.parent_command_error(command)
      {:error, error, _events} -> {:error, error}
    end
  end

  def graph_input(%{graph: %{input_schema: input_schema}}, input) when is_map(input) do
    case schema_key_names(input_schema) do
      [] -> input
      keys -> Map.filter(input, fn {key, _value} -> to_string(key) in keys end)
    end
  end

  def graph_output(%{graph: %{output_schema: output_schema}}, output) when is_map(output) do
    case schema_key_names(output_schema) do
      [] -> output
      keys -> Map.filter(output, fn {key, _value} -> to_string(key) in keys end)
    end
  end

  def graph_output(_compiled, output), do: output

  def rebase_time_travel_opts(opts, compiled) do
    case Keyword.fetch(opts, :config) do
      {:ok, config} when is_map(config) ->
        rebased = SubgraphRouter.rebase_time_travel_config(compiled, config)

        opts
        |> Keyword.put(:config, rebased)
        |> maybe_clear_rebased_pending_writes(config, rebased)

      _other ->
        opts
    end
  end

  defp do_stream(compiled, input, opts, true), do: live_stream(compiled, input, opts)

  defp do_stream(compiled, input, opts, false) do
    case Runner.execute(compiled, input, opts) do
      {:ok, _result, events} -> {:ok, events}
      {:interrupted, interrupt, events} -> {:interrupted, Map.put(interrupt, :events, events)}
      {:parent_command, command, _events} -> CommandRouter.parent_command_error(command)
      {:error, error, _events} -> {:error, error}
    end
  end

  defp live_stream(compiled, input, opts) do
    modes = ExecutionStream.normalize_modes(Keyword.get(opts, :stream_mode, :updates))

    producer =
      {:sink, compiled.name,
       fn sink ->
         opts =
           opts
           |> Keyword.put(:collect_stream?, true)
           |> Keyword.put(:stream_sink, sink)

         case Runner.execute(compiled, input, opts) do
           {:ok, _result, _events} ->
             :ok

           {:interrupted, interrupt, _events} ->
             BeamWeaver.Stream.Sink.emit(
               sink,
               BWStream.envelope(
                 BWStream.event(:debug, %{type: :interrupt, interrupt: interrupt}),
                 run_id: Map.get(interrupt, :run_id),
                 graph: compiled.name,
                 namespace: Map.get(interrupt, :namespace, [])
               )
             )

           {:parent_command, command, _events} ->
             BeamWeaver.Stream.Sink.emit(
               sink,
               BWStream.envelope(
                 BWStream.event(:debug, %{type: :parent_command, command: command}),
                 graph: compiled.name
               )
             )

           {:error, %Error{} = error, _events} ->
             {:error, error}
         end
       end}

    stream =
      [producer]
      |> BWStream.mux(
        run_id: Keyword.get(opts, :run_id),
        graph: compiled.name,
        heartbeat: Keyword.get(opts, :heartbeat),
        max_buffer: Keyword.get(opts, :max_buffer, 256),
        overflow: Keyword.get(opts, :overflow, :block),
        timeout: Keyword.get(opts, :stream_timeout, :infinity),
        cancel_timeout: Keyword.get(opts, :cancel_timeout, 100),
        producer_supervisor: Keyword.get(opts, :producer_supervisor)
      )
      |> Elixir.Stream.map(&BWStream.format(&1, modes))

    {:ok, stream}
  end

  defp lifecycle_events(compiled, events, opts, status) do
    run_id = Keyword.get(opts, :run_id)
    namespace = Keyword.get(opts, :namespace, [])
    metadata = Keyword.get(opts, :metadata, %{})

    started =
      BWStream.envelope(
        BWStream.event(:debug, %{type: :start, status: :running}),
        run_id: run_id,
        graph: compiled.name,
        namespace: namespace,
        metadata: metadata
      )

    done =
      BWStream.envelope(
        BWStream.event(:done, %{result: %{status: status}}),
        run_id: run_id,
        graph: compiled.name,
        namespace: namespace,
        metadata: metadata
      )

    [started | Enum.to_list(events)] ++ [done]
  end

  defp maybe_clear_rebased_pending_writes(opts, config, rebased) when config != rebased,
    do: Keyword.put(opts, :clear_pending_writes?, true)

  defp maybe_clear_rebased_pending_writes(opts, _config, _rebased), do: opts

  defp schema_key_names(nil), do: []

  defp schema_key_names(%{"properties" => properties}) when is_map(properties) do
    properties |> Map.keys() |> Enum.map(&to_string/1)
  end

  defp schema_key_names(%{properties: properties}) when is_map(properties) do
    properties |> Map.keys() |> Enum.map(&to_string/1)
  end

  defp schema_key_names(schema) when is_map(schema) do
    schema |> Map.keys() |> Enum.map(&to_string/1)
  end

  defp schema_key_names(_schema), do: []
end
