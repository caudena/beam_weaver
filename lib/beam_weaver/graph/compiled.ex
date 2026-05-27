defmodule BeamWeaver.Graph.Compiled do
  @moduledoc """
  Executable graph produced by `BeamWeaver.Graph.StateGraph.compile/2`.

  This module is the public facade. Graph execution runtime internals live under
  `BeamWeaver.Graph.Execution`.
  """

  alias BeamWeaver.Core.Async
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Graph.Command
  alias BeamWeaver.Graph.Compiled.Batch
  alias BeamWeaver.Graph.Compiled.CacheControl
  alias BeamWeaver.Graph.Compiled.Runtime
  alias BeamWeaver.Graph.Compiled.View
  alias BeamWeaver.Graph.Execution.StateUpdate
  alias BeamWeaver.Graph.Introspection
  alias BeamWeaver.Graph.StateGraph

  defstruct [
    :name,
    :graph,
    :plan,
    :checkpointer,
    :store,
    interrupt_before: MapSet.new(),
    interrupt_after: MapSet.new(),
    failure_policy: :panic,
    step_timeout: :infinity,
    run_timeout: :infinity,
    debug: false,
    cache: %{},
    checkpoint_scope: :inherit
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          graph: StateGraph.t(),
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
    Batch.batch(compiled, inputs, opts)
  end

  @spec batch_as_completed(t(), [map()], keyword()) ::
          {:ok, Enumerable.t()} | {:error, Error.t()}
  def batch_as_completed(%__MODULE__{} = compiled, inputs, opts \\ []) when is_list(inputs) do
    Batch.batch_as_completed(compiled, inputs, opts)
  end

  @spec async_invoke(t(), map(), keyword()) :: Async.handle()
  def async_invoke(%__MODULE__{} = compiled, input, opts \\ []) do
    Async.run_call(opts, &invoke(compiled, input, &1))
  end

  @spec async_batch(t(), [map()], keyword()) :: [Async.handle()]
  def async_batch(%__MODULE__{} = compiled, inputs, opts \\ []) when is_list(inputs) do
    Async.batch_call(inputs, opts, &invoke(compiled, &1, &2))
  end

  @spec async_batch_as_completed(t(), [map()], keyword()) :: Async.handle()
  def async_batch_as_completed(%__MODULE__{} = compiled, inputs, opts \\ [])
      when is_list(inputs) do
    Async.run_call(opts, &batch_as_completed(compiled, inputs, &1))
  end

  @doc """
  Streams typed graph events with lifecycle envelopes.

  This is the BeamWeaver-native graph event facade. It returns typed envelopes
  with a stable start/done boundary without exposing graph execution runner
  internals.
  """
  @spec stream_events(t(), map() | Command.t(), keyword()) ::
          {:ok, Enumerable.t()} | {:interrupted, map()} | {:error, Error.t()}
  def stream_events(%__MODULE__{} = compiled, input, opts \\ []) do
    Runtime.stream_events(compiled, input, opts)
  end

  @spec async_stream_events(t(), map() | Command.t(), keyword()) :: Async.handle()
  def async_stream_events(%__MODULE__{} = compiled, input, opts \\ []) do
    Async.run_call(opts, &stream_events(compiled, input, &1))
  end

  @doc """
  Resumes the latest interrupted checkpoint with a value or interrupt-id map.
  """
  @spec resume(t(), term(), keyword()) ::
          {:ok, map()} | {:interrupted, map()} | {:error, Error.t()}
  def resume(%__MODULE__{} = compiled, resume, opts \\ []) do
    Runtime.resume(compiled, resume, opts)
  end

  @spec async_resume(t(), term(), keyword()) :: Async.handle()
  def async_resume(%__MODULE__{} = compiled, resume, opts \\ []) do
    Async.run_call(opts, &resume(compiled, resume, &1))
  end

  @doc "Returns the latest checkpointed state for a graph configuration."
  @spec get_state(t(), map()) :: {:ok, map()} | :error
  defdelegate get_state(compiled, config), to: StateUpdate

  @spec async_get_state(t(), map(), keyword()) :: Async.handle()
  def async_get_state(%__MODULE__{} = compiled, config, opts \\ []) do
    Async.run_call(opts, fn _call_opts -> get_state(compiled, config) end)
  end

  def get_state_history(compiled, config, opts \\ [])

  @doc "Returns checkpointed state history for a graph configuration."
  @spec get_state_history(t(), map(), keyword()) :: [map()]
  defdelegate get_state_history(compiled, config, opts), to: StateUpdate

  @spec async_get_state_history(t(), map(), keyword()) :: Async.handle()
  def async_get_state_history(%__MODULE__{} = compiled, config, opts \\ []) do
    Async.run_call(opts, &get_state_history(compiled, config, &1))
  end

  def update_state(compiled, config, values, opts \\ [])

  @doc "Applies a state update to a checkpointed graph configuration."
  @spec update_state(t(), map(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  defdelegate update_state(compiled, config, values, opts), to: StateUpdate

  @spec async_update_state(t(), map(), map(), keyword()) :: Async.handle()
  def async_update_state(%__MODULE__{} = compiled, config, values, opts \\ []) do
    Async.run_call(opts, &update_state(compiled, config, values, &1))
  end

  def bulk_update_state(compiled, config, supersteps, opts \\ [])

  @doc "Applies a bulk state update to a checkpointed graph configuration."
  @spec bulk_update_state(t(), map(), [[map()]], keyword()) :: {:ok, map()} | {:error, Error.t()}
  defdelegate bulk_update_state(compiled, config, supersteps, opts), to: StateUpdate

  @spec async_bulk_update_state(t(), map(), [[map()]], keyword()) :: Async.handle()
  def async_bulk_update_state(%__MODULE__{} = compiled, config, supersteps, opts \\ []) do
    Async.run_call(opts, &bulk_update_state(compiled, config, supersteps, &1))
  end

  @doc """
  Clears the explicit graph cache adapter.

  When a graph was compiled without a cache adapter this is a no-op. A namespace
  can be supplied to clear only one graph/node cache namespace.
  """
  @spec clear_cache(t(), keyword()) :: :ok | {:error, Error.t()}
  def clear_cache(%__MODULE__{} = compiled, opts \\ []) do
    CacheControl.clear_cache(compiled, opts)
  end

  @spec async_clear_cache(t(), keyword()) :: Async.handle()
  def async_clear_cache(%__MODULE__{} = compiled, opts \\ []) do
    Async.run_call(opts, &clear_cache(compiled, &1))
  end

  @spec get_graph(t(), keyword()) :: Introspection.t()
  def get_graph(%__MODULE__{} = compiled, opts \\ []) do
    View.get_graph(compiled, opts)
  end

  @spec get_context_json_schema(t()) :: map()
  def get_context_json_schema(%__MODULE__{graph: %{context_schema: context_schema}}) do
    View.get_context_json_schema(%{graph: %{context_schema: context_schema}})
  end

  @spec get_input_json_schema(t()) :: map()
  def get_input_json_schema(%__MODULE__{graph: %{input_schema: input_schema}}) do
    View.get_input_json_schema(%{graph: %{input_schema: input_schema}})
  end

  @spec get_output_json_schema(t()) :: map()
  def get_output_json_schema(%__MODULE__{graph: %{output_schema: output_schema}}) do
    View.get_output_json_schema(%{graph: %{output_schema: output_schema}})
  end

  @spec draw_mermaid(t(), keyword()) :: String.t()
  def draw_mermaid(%__MODULE__{} = compiled, opts \\ []) do
    View.draw_mermaid(compiled, opts)
  end

  @spec draw_ascii(t(), keyword()) :: String.t()
  def draw_ascii(%__MODULE__{} = compiled, opts \\ []) do
    View.draw_ascii(compiled, opts)
  end

  @spec draw_png(t(), keyword()) :: {:ok, binary()} | {:error, Error.t()}
  def draw_png(%__MODULE__{} = compiled, opts \\ []) do
    View.draw_png(compiled, opts)
  end
end
