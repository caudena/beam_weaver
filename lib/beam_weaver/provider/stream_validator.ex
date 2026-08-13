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

  @type t :: %__MODULE__{
          error: Error.t() | nil,
          event_count: non_neg_integer(),
          transport_bytes: non_neg_integer(),
          value_bytes: non_neg_integer(),
          max_events: pos_integer(),
          max_transport_bytes: pos_integer(),
          max_value_bytes: pos_integer(),
          validation: keyword()
        }

  @doc """
  Creates validation state with optional event, transport-byte, value-byte,
  item, and nesting limits.

  The defaults are 100,000 events, 64 MiB of transport bytes, 64 MiB of
  decoded values, 100,000 decoded items, and a nesting depth of 64.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      max_events: Keyword.get(opts, :max_stream_events, 100_000),
      max_transport_bytes: Keyword.get(opts, :max_stream_bytes, 64 * 1024 * 1024),
      max_value_bytes: Keyword.get(opts, :max_stream_value_bytes, 64 * 1024 * 1024),
      validation: Keyword.take(opts, [:max_bytes, :max_items, :max_depth])
    }
  end

  @doc """
  Validates one event or one event batch without exposing partial progress.

  `:transport_bytes` records the encoded bytes consumed for the batch. Once a
  push fails, the returned state keeps the first error and rejects later work.
  """
  @spec push(t(), term() | [term()], keyword()) ::
          {:ok, t()} | {:error, Error.t(), t()}
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

  @doc """
  Finishes validation, returning the first sticky error when one occurred.
  """
  @spec finish(t()) :: :ok | {:error, Error.t()}
  def finish(%__MODULE__{error: %Error{} = error}), do: {:error, error}
  def finish(%__MODULE__{}), do: :ok

  @doc """
  Marks decoder or parser failure as the stream's first sticky error.
  """
  @spec reject(t(), term()) :: {:error, Error.t(), t()}
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
