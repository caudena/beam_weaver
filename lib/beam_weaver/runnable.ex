defmodule BeamWeaver.Runnable do
  @moduledoc """
  LangChain-compatible executable composition, translated into Elixir.

  Runnables are plain structs or functions that support `invoke/3`, `batch/3`,
  and `stream/3` through this facade. Composition is explicit and pipe-friendly.
  """

  alias BeamWeaver.Core.Async
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Runnable.Runtime

  @callback invoke(term(), term(), keyword()) :: {:ok, term()} | {:error, Error.t()}
  @callback batch(term(), [term()], keyword()) :: {:ok, [term()]} | {:error, Error.t()}
  @callback stream(term(), term(), keyword()) :: {:ok, Enumerable.t()} | {:error, Error.t()}
  @callback transform(term(), Enumerable.t(), keyword()) ::
              {:ok, Enumerable.t()} | {:error, Error.t()}
  @optional_callbacks batch: 3, stream: 3, transform: 3

  @type runnable :: term()

  def lambda(fun, opts \\ []), do: %BeamWeaver.Runnable.Lambda{fun: fun, name: opts[:name]}

  def sequence(runnables, opts \\ []),
    do: %BeamWeaver.Runnable.Sequence{steps: List.wrap(runnables), name: opts[:name]}

  def pipe(runnable, others, opts \\ []) do
    sequence([runnable | List.wrap(others)], opts)
  end

  def parallel(runnables), do: %BeamWeaver.Runnable.Parallel{steps: runnables}
  def map(runnable), do: %BeamWeaver.Runnable.Map{runnable: runnable}
  def each(runnable), do: %BeamWeaver.Runnable.Each{runnable: runnable}
  def generator(fun, opts \\ []), do: %BeamWeaver.Runnable.Generator{fun: fun, name: opts[:name]}
  def passthrough, do: %BeamWeaver.Runnable.Passthrough{}

  def assign(base \\ passthrough(), assignments),
    do: %BeamWeaver.Runnable.Assign{base: base, assignments: assignments}

  def pick(keys), do: %BeamWeaver.Runnable.Pick{keys: List.wrap(keys)}
  def branch(branches), do: %BeamWeaver.Runnable.Branch{branches: branches}
  def router(routes), do: %BeamWeaver.Runnable.Router{routes: Map.new(routes)}

  def with_retry(runnable, opts \\ []),
    do: %BeamWeaver.Runnable.Retry{runnable: runnable, opts: opts}

  def with_fallbacks(runnable, fallbacks, opts \\ []),
    do: %BeamWeaver.Runnable.Fallback{
      runnable: runnable,
      fallbacks: List.wrap(fallbacks),
      opts: opts
    }

  def bind(runnable, bound_opts),
    do: %BeamWeaver.Runnable.Binding{runnable: runnable, bound_opts: bound_opts}

  def with_config(runnable, opts),
    do: %BeamWeaver.Runnable.WithConfig{runnable: runnable, opts: opts}

  def with_types(runnable, opts),
    do: %BeamWeaver.Runnable.WithTypes{
      runnable: runnable,
      input_schema: Keyword.get(opts, :input),
      output_schema: Keyword.get(opts, :output)
    }

  def config_field(field, opts \\ []), do: BeamWeaver.Runnable.ConfigField.new(field, opts)

  def configure(runnable, fields) do
    fields =
      Map.new(fields, fn
        {field, %BeamWeaver.Runnable.ConfigField{} = spec} -> {field, %{spec | field: field}}
        {field, opts} when is_list(opts) -> {field, config_field(field, opts)}
        field when is_atom(field) or is_binary(field) -> {field, config_field(field)}
      end)

    %BeamWeaver.Runnable.Configured{runnable: runnable, fields: fields}
  end

  def alternatives(runnable, field, alternatives, opts \\ []) do
    %BeamWeaver.Runnable.Alternatives{
      default: runnable,
      field: field,
      alternatives: Map.new(alternatives),
      opts: opts
    }
  end

  def with_history(runnable, opts) do
    %BeamWeaver.Runnable.MessageHistory{runnable: runnable, opts: opts}
  end

  def with_listeners(runnable, opts \\ []) do
    %BeamWeaver.Runnable.Listener{
      runnable: runnable,
      listeners: Keyword.take(opts, [:on_start, :on_end, :on_error]),
      async?: false
    }
  end

  def with_alisteners(runnable, opts \\ []) do
    %BeamWeaver.Runnable.Listener{
      runnable: runnable,
      listeners: Keyword.take(opts, [:on_start, :on_end, :on_error]),
      async?: true
    }
  end

  def as_tool(runnable, opts \\ []), do: BeamWeaver.Tool.Converter.to_tool(runnable, opts)

  def get_name(runnable), do: name(runnable)

  @doc "Returns the display name for a runnable."
  defdelegate name(runnable), to: Runtime

  @spec async_invoke(runnable(), term(), keyword()) :: Async.handle()
  def async_invoke(runnable, input, opts \\ []) do
    Async.run_call(opts, &invoke(runnable, input, &1))
  end

  @spec async_batch(runnable(), [term()], keyword()) :: Async.handle()
  def async_batch(runnable, inputs, opts \\ []) do
    Async.run_call(opts, &batch(runnable, inputs, &1))
  end

  @spec async_batch_as_completed(runnable(), [term()], keyword()) :: Async.handle()
  def async_batch_as_completed(runnable, inputs, opts \\ []) do
    Async.run_call(opts, &batch_as_completed(runnable, inputs, &1))
  end

  @spec async_stream(runnable(), term(), keyword()) :: Async.handle()
  def async_stream(runnable, input, opts \\ []) do
    Async.run_call(opts, &stream(runnable, input, &1))
  end

  @spec async_transform(runnable(), Enumerable.t(), keyword()) :: Async.handle()
  def async_transform(runnable, input, opts \\ []) do
    Async.run_call(opts, &transform(runnable, input, &1))
  end

  @spec async_stream_events(runnable(), term(), keyword()) :: Async.handle()
  def async_stream_events(runnable, input, opts \\ []) do
    Async.run_call(opts, &stream_events(runnable, input, &1))
  end

  @spec async_stream_log(runnable(), term(), keyword()) :: Async.handle()
  def async_stream_log(runnable, input, opts \\ []) do
    Async.run_call(opts, &stream_log(runnable, input, &1))
  end

  @doc "Invokes a runnable with one input."
  @spec invoke(runnable(), term(), keyword()) :: {:ok, term()} | {:error, Error.t()}
  defdelegate invoke(runnable, input, opts \\ []), to: Runtime

  @doc "Invokes a runnable for each input and returns ordered results."
  @spec batch(runnable(), [term()], keyword()) :: {:ok, [term()]} | {:error, Error.t()}
  defdelegate batch(runnable, inputs, opts \\ []), to: Runtime

  @doc "Invokes a runnable for each input and streams results as they complete."
  @spec batch_as_completed(runnable(), [term()], keyword()) ::
          {:ok, Enumerable.t()} | {:error, Error.t()}
  defdelegate batch_as_completed(runnable, inputs, opts \\ []), to: Runtime

  @doc "Streams a runnable result for one input."
  @spec stream(runnable(), term(), keyword()) :: {:ok, Enumerable.t()} | {:error, Error.t()}
  defdelegate stream(runnable, input, opts \\ []), to: Runtime

  @doc "Transforms an input enumerable through a runnable."
  @spec transform(runnable(), Enumerable.t(), keyword()) ::
          {:ok, Enumerable.t()} | {:error, Error.t()}
  defdelegate transform(runnable, input, opts \\ []), to: Runtime

  @doc "Streams typed runnable events."
  @spec stream_events(runnable(), term(), keyword()) ::
          {:ok, Enumerable.t()} | {:error, Error.t()}
  defdelegate stream_events(runnable, input, opts \\ []), to: Runtime

  @doc "Streams runnable log-style event records."
  @spec stream_log(runnable(), term(), keyword()) :: {:ok, Enumerable.t()} | {:error, Error.t()}
  defdelegate stream_log(runnable, input, opts \\ []), to: Runtime

  def to_spec(runnable), do: BeamWeaver.Runnable.Spec.to_spec(coerce(runnable))

  def from_spec(spec, opts \\ []) do
    BeamWeaver.Runnable.Registry.build(Keyword.get(opts, :registry), spec)
  end

  def get_graph(runnable, opts \\ []),
    do: BeamWeaver.Runnable.Introspect.graph(coerce(runnable), opts)

  def input_schema(runnable), do: BeamWeaver.Runnable.Introspect.input_schema(coerce(runnable))
  def output_schema(runnable), do: BeamWeaver.Runnable.Introspect.output_schema(coerce(runnable))

  def config_specs(runnable) do
    runnable
    |> coerce()
    |> BeamWeaver.Runnable.Introspect.config_specs()
    |> Map.new(&{&1.id, &1})
    |> Map.values()
  end

  def draw_mermaid(runnable, opts \\ []) do
    runnable |> get_graph(opts) |> BeamWeaver.Runnable.Graph.Renderer.to_mermaid(opts)
  end

  def draw_ascii(runnable, opts \\ []) do
    runnable |> get_graph(opts) |> BeamWeaver.Runnable.Graph.Renderer.to_ascii(opts)
  end

  def draw_png(runnable, opts \\ []) do
    runnable |> get_graph(opts) |> BeamWeaver.Runnable.Graph.Renderer.to_png(opts)
  end

  @doc false
  defdelegate coerce(runnable), to: Runtime
end
