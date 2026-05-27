defmodule BeamWeaver.Stream.HeartbeatPolicy do
  @moduledoc """
  Opt-in heartbeat policy for live streams.
  """

  defstruct interval_ms: nil,
            event_mode_only?: true,
            payload: %{type: :heartbeat}

  @type t :: %__MODULE__{
          interval_ms: pos_integer() | nil,
          event_mode_only?: boolean(),
          payload: map()
        }

  @spec new(nil | pos_integer() | keyword() | t()) :: t() | nil
  def new(nil), do: nil
  def new(%__MODULE__{} = policy), do: policy

  def new(interval_ms) when is_integer(interval_ms) and interval_ms > 0 do
    %__MODULE__{interval_ms: interval_ms}
  end

  def new(opts) when is_list(opts) do
    interval = Keyword.get(opts, :interval_ms, Keyword.get(opts, :interval))

    if is_integer(interval) and interval > 0 do
      %__MODULE__{
        interval_ms: interval,
        event_mode_only?: Keyword.get(opts, :event_mode_only?, true),
        payload: Keyword.get(opts, :payload, %{type: :heartbeat})
      }
    end
  end
end

defmodule BeamWeaver.Stream.Policy do
  @moduledoc """
  Runtime policy for live stream producers.

  Backpressure is owned by the mux process. Producers emit through a
  `BeamWeaver.Stream.Sink`, which either blocks, drops, or errors according to
  this policy.
  """

  alias BeamWeaver.Stream.HeartbeatPolicy

  @overflow [:block, :drop_newest, :drop_oldest, :error]

  defstruct max_buffer: 256,
            overflow: :block,
            emit_timeout: 5_000,
            timeout: :infinity,
            producer_supervisor: nil,
            cancel_timeout: 100,
            heartbeat: nil

  @type overflow :: :block | :drop_newest | :drop_oldest | :error
  @type t :: %__MODULE__{
          max_buffer: non_neg_integer(),
          overflow: overflow(),
          emit_timeout: timeout(),
          timeout: timeout(),
          producer_supervisor: atom() | pid() | nil,
          cancel_timeout: timeout(),
          heartbeat: HeartbeatPolicy.t() | nil
        }

  @spec new(keyword() | map() | t()) :: t()
  def new(%__MODULE__{} = policy), do: policy
  def new(opts) when is_map(opts), do: opts |> Map.to_list() |> new()

  def new(opts) when is_list(opts) do
    heartbeat =
      opts
      |> Keyword.get(:heartbeat)
      |> HeartbeatPolicy.new()

    %__MODULE__{
      max_buffer: normalize_max_buffer(Keyword.get(opts, :max_buffer, 256)),
      overflow: normalize_overflow(Keyword.get(opts, :overflow, :block)),
      emit_timeout: normalize_timeout(Keyword.get(opts, :emit_timeout, 5_000)),
      timeout: normalize_timeout(Keyword.get(opts, :timeout, :infinity)),
      producer_supervisor: Keyword.get(opts, :producer_supervisor),
      cancel_timeout: normalize_timeout(Keyword.get(opts, :cancel_timeout, 100)),
      heartbeat: heartbeat
    }
  end

  defp normalize_max_buffer(value) when is_integer(value) and value >= 0, do: value
  defp normalize_max_buffer(_value), do: 256

  defp normalize_overflow(value) when value in @overflow, do: value

  defp normalize_overflow("block"), do: :block
  defp normalize_overflow("drop_newest"), do: :drop_newest
  defp normalize_overflow("drop_oldest"), do: :drop_oldest
  defp normalize_overflow("error"), do: :error

  defp normalize_overflow(_value), do: :block

  defp normalize_timeout(:infinity), do: :infinity
  defp normalize_timeout(nil), do: :infinity
  defp normalize_timeout(value) when is_integer(value) and value >= 0, do: value
  defp normalize_timeout(_value), do: :infinity
end
