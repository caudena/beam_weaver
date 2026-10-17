defmodule BeamWeaver.Graph.Compiled do
  @moduledoc """
  A graph compiled with `BeamWeaver.Graph.compile/2`, ready to run.

  `invoke/3` runs it to the end, `stream_events/3` streams typed events,
  `resume/3` continues an interrupted thread, and `get_state/2`,
  `get_state_history/3` and `update_state/4` read and change checkpointed
  threads. See [Graphs](graphs.md) and [Checkpoints](checkpoints.md).

  With a checkpointer, an empty input means "no new input": when the thread's
  last run stopped before its end, at a breakpoint or in a crash, `invoke/3`
  and `stream_events/3` continue that run.
  """

  alias BeamWeaver.Cache
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Graph.Command
  alias BeamWeaver.Graph.Compiled.Runtime
  alias BeamWeaver.Graph.Execution.StateUpdate
  alias BeamWeaver.Graph.Introspection
  alias BeamWeaver.Graph.Renderer
  alias BeamWeaver.Schema

  defstruct [
    :name,
    :graph,
    :plan,
    :checkpointer,
    :store,
    interrupt_before: MapSet.new(),
    interrupt_after: MapSet.new(),
    step_timeout: :infinity,
    run_timeout: :infinity,
    debug: false,
    cache: %{},
    checkpoint_scope: :inherit
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          graph: BeamWeaver.Graph.t(),
          plan: map(),
          checkpointer: struct() | nil,
          checkpoint_scope: :inherit | :shared | :disabled | :local,
          store: struct() | nil
        }

  def invoke(compiled, input, opts \\ [])

  @spec invoke(t(), map() | Command.t(), keyword()) ::
          {:ok, map()} | {:interrupted, map()} | {:error, Error.t()}
  def invoke(%__MODULE__{} = compiled, input, opts), do: Runtime.invoke(compiled, input, opts)

  def invoke(_compiled, _input, _opts),
    do: {:error, Error.new(:invalid_input, "graph input must be a map")}

  @spec batch(t(), [map()], keyword()) :: [term()]
  def batch(%__MODULE__{} = compiled, inputs, opts \\ []) when is_list(inputs) do
    Enum.map(inputs, &Runtime.invoke(compiled, &1, opts))
  end

  @spec batch_as_completed(t(), [map()], keyword()) ::
          {:ok, Enumerable.t()} | {:error, Error.t()}
  def batch_as_completed(%__MODULE__{} = compiled, inputs, opts \\ []) when is_list(inputs) do
    max_concurrency =
      case Keyword.get(opts, :max_concurrency, System.schedulers_online()) do
        value when is_integer(value) and value > 0 -> value
        _value -> System.schedulers_online()
      end

    stream =
      inputs
      |> Enum.with_index()
      |> Task.async_stream(
        fn {input, index} -> {index, Runtime.invoke(compiled, input, opts)} end,
        ordered: false,
        max_concurrency: max_concurrency,
        timeout: Keyword.get(opts, :timeout, :infinity),
        on_timeout: :kill_task
      )
      |> Elixir.Stream.map(fn
        {:ok, {index, result}} ->
          {index, result}

        {:exit, reason} ->
          {:unknown, {:error, Error.new(:graph_batch_exit, "graph batch task exited", %{reason: inspect(reason)})}}
      end)

    {:ok, stream}
  rescue
    exception ->
      {:error,
       Error.new(:graph_batch_exception, Exception.message(exception), %{
         exception: inspect(exception.__struct__)
       })}
  end

  @doc """
  Runs the graph and returns its events as `BeamWeaver.Stream.Envelope` structs.

  With `live: true` it returns `{:ok, stream}` at once, and the graph runs while
  you read the stream; a failed run ends the stream with an `Error` event.
  Without it the graph runs to the end first and the same events, in the same
  order, come back as `{:ok, events}`, as `interrupt.events` in
  `{:interrupted, interrupt}`, or not at all in `{:error, error}`.

  Takes the options of `invoke/3`, and:

    * `:live` - stream the events while the graph runs.
    * `:stream_mode` - keep only events of these channels (see
      `BeamWeaver.Stream.event_mode/1`), such as `[:messages, :tools]`.
      Defaults to `:events`, every event; `Error` events always arrive.

  See [Streaming](streaming.md).
  """
  @spec stream_events(t(), map() | Command.t(), keyword()) ::
          {:ok, Enumerable.t()} | {:interrupted, map()} | {:error, Error.t()}
  def stream_events(%__MODULE__{} = compiled, input, opts \\ []) do
    Runtime.stream_events(compiled, input, opts)
  end

  @doc """
  Continues the thread from its latest checkpoint.

  `resume` answers the pending interrupts: a value for a single one, or a map
  from interrupt id to value. The run then goes on with the nodes the thread
  had left, past a breakpoint it stopped at. Pass `nil` when nothing waits
  for an answer, such as after a breakpoint or a crash. A thread with nothing
  left to run returns its state.
  """
  @spec resume(t(), term(), keyword()) ::
          {:ok, map()} | {:interrupted, map()} | {:error, Error.t()}
  def resume(%__MODULE__{} = compiled, resume, opts \\ []) do
    Runtime.resume(compiled, resume, opts)
  end

  @doc "Returns the latest checkpointed state for a graph configuration."
  @spec get_state(t(), map()) :: {:ok, map()} | :error | {:error, Error.t()}
  defdelegate get_state(compiled, config), to: StateUpdate

  def get_state_history(compiled, config, opts \\ [])

  @doc "Returns checkpointed state history for a graph configuration."
  @spec get_state_history(t(), map(), keyword()) :: [map()] | {:error, Error.t()}
  defdelegate get_state_history(compiled, config, opts), to: StateUpdate

  def update_state(compiled, config, values, opts \\ [])

  @doc "Applies a state update to a checkpointed graph configuration."
  @spec update_state(t(), map(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  defdelegate update_state(compiled, config, values, opts), to: StateUpdate

  def bulk_update_state(compiled, config, supersteps, opts \\ [])

  @doc "Applies a bulk state update to a checkpointed graph configuration."
  @spec bulk_update_state(t(), map(), [[map()]], keyword()) :: {:ok, map()} | {:error, Error.t()}
  defdelegate bulk_update_state(compiled, config, supersteps, opts), to: StateUpdate

  @doc """
  Clears the explicit graph cache adapter.

  When a graph was compiled without a cache adapter this is a no-op. A namespace
  can be supplied to clear only one graph/node cache namespace.
  """
  @spec clear_cache(t(), keyword()) :: :ok | {:error, Error.t()}
  def clear_cache(%__MODULE__{} = compiled, opts \\ []) do
    cache = Keyword.get(opts, :cache, compiled.cache)

    cond do
      Cache.adapter?(cache) ->
        Cache.clear(cache, Keyword.get(opts, :namespace))

      cache in [nil, false, %{}] ->
        :ok

      true ->
        {:error,
         Error.new(:invalid_cache, "graph cache must be a BeamWeaver.Cache adapter", %{
           cache: inspect(cache)
         })}
    end
  end

  @spec get_graph(t(), keyword()) :: Introspection.t()
  def get_graph(%__MODULE__{} = compiled, opts \\ []) do
    Introspection.from_compiled(compiled, opts)
  end

  @spec get_context_json_schema(t()) :: map()
  def get_context_json_schema(%__MODULE__{graph: %{context_schema: context_schema}}) do
    Schema.to_json_schema(context_schema)
  end

  @spec get_input_json_schema(t()) :: map()
  def get_input_json_schema(%__MODULE__{graph: %{input_schema: input_schema}}) do
    Schema.to_json_schema(input_schema)
  end

  @spec get_output_json_schema(t()) :: map()
  def get_output_json_schema(%__MODULE__{graph: %{output_schema: output_schema}}) do
    Schema.to_json_schema(output_schema)
  end

  @spec draw_mermaid(t(), keyword()) :: String.t()
  def draw_mermaid(%__MODULE__{} = compiled, opts \\ []) do
    compiled |> get_graph(opts) |> Renderer.to_mermaid(opts)
  end

  @spec draw_ascii(t(), keyword()) :: String.t()
  def draw_ascii(%__MODULE__{} = compiled, opts \\ []) do
    compiled |> get_graph(opts) |> Renderer.to_ascii(opts)
  end

  @spec draw_png(t(), keyword()) :: {:ok, binary()} | {:error, Error.t()}
  def draw_png(%__MODULE__{} = compiled, opts \\ []) do
    compiled |> get_graph(opts) |> Renderer.to_png(opts)
  end
end
