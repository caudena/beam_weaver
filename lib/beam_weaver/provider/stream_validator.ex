defmodule BeamWeaver.Provider.StreamValidator do
  @moduledoc """
  Bounded, sticky validation state for provider stream events.

  Once a batch fails, the first error is returned by every later `push/3` and
  `finish/1` call. A failed batch never advances counters or exposes a partial
  candidate state.
  """

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Provider.Validation

  defstruct error: nil,
            event_count: 0,
            transport_bytes: 0,
            value_bytes: 0,
            max_events: 100_000,
            max_transport_bytes: 64 * 1024 * 1024,
            max_value_bytes: 64 * 1024 * 1024,
            validation: []

  def new(opts \\ []) do
    %__MODULE__{
      max_events: Keyword.get(opts, :max_stream_events, 100_000),
      max_transport_bytes: Keyword.get(opts, :max_stream_bytes, 64 * 1024 * 1024),
      max_value_bytes: Keyword.get(opts, :max_stream_value_bytes, 64 * 1024 * 1024),
      validation: Keyword.take(opts, [:max_bytes, :max_items, :max_depth])
    }
  end

  def push(state, events, opts \\ [])

  def push(%__MODULE__{error: %Error{} = error} = state, _events, _opts),
    do: {:error, error, state}

  def push(%__MODULE__{} = state, events, opts) do
    events = if is_list(events), do: events, else: [events]
    transport_bytes = Keyword.get(opts, :transport_bytes, 0)

    with true <- is_integer(transport_bytes) and transport_bytes >= 0,
         true <- state.event_count + length(events) <= state.max_events,
         true <- state.transport_bytes + transport_bytes <= state.max_transport_bytes,
         {:ok, value_bytes} <- measure(events, state.validation),
         true <- state.value_bytes + value_bytes <= state.max_value_bytes do
      {:ok,
       %{
         state
         | event_count: state.event_count + length(events),
           transport_bytes: state.transport_bytes + transport_bytes,
           value_bytes: state.value_bytes + value_bytes
       }}
    else
      false -> fail(state, "provider stream exceeds its configured bounds")
      {:error, %Error{} = error} -> fail(state, error)
    end
  end

  def finish(%__MODULE__{error: %Error{} = error}), do: {:error, error}
  def finish(%__MODULE__{}), do: :ok

  def reject(%__MODULE__{error: %Error{} = error} = state, _reason),
    do: {:error, error, state}

  def reject(%__MODULE__{} = state, reason),
    do: fail(state, Error.new(:invalid_provider_stream, "provider stream decoder failed", %{reason: inspect(reason)}))

  defp measure(events, opts) do
    Enum.reduce_while(events, {:ok, 0}, fn event, {:ok, bytes} ->
      case Validation.measure(event, opts) do
        {:ok, measured} -> {:cont, {:ok, bytes + measured.bytes}}
        {:error, %Error{}} = error -> {:halt, error}
      end
    end)
  end

  defp fail(state, message) when is_binary(message),
    do: fail(state, Error.new(:invalid_provider_stream, message))

  defp fail(state, %Error{} = error) do
    failed = %{state | error: error}
    {:error, error, failed}
  end
end
