defmodule BeamWeaver.Memory.TTLSweeper do
  @moduledoc """
  Periodic TTL cleanup for memory stores.

  The sweeper is intentionally store-agnostic: adapters keep their own
  `sweep_expired/2` implementation, while callers decide how to supervise this
  process.
  """

  use GenServer

  alias BeamWeaver.Memory

  defstruct [:store, :interval, opts: []]

  @type t :: %__MODULE__{
          store: term(),
          interval: pos_integer(),
          opts: keyword()
        }

  @spec start_link(term(), keyword()) :: GenServer.on_start()
  def start_link(store, opts \\ []) do
    gen_opts = Keyword.take(opts, [:name])
    GenServer.start_link(__MODULE__, {store, opts}, gen_opts)
  end

  @spec stop(pid() | atom(), timeout()) :: :ok
  def stop(server, timeout \\ 5_000), do: GenServer.stop(server, :normal, timeout)

  @impl true
  def init({store, opts}) do
    state = %__MODULE__{
      store: store,
      interval: Keyword.get(opts, :interval, 60_000),
      opts: Keyword.get(opts, :sweep_opts, [])
    }

    if Keyword.get(opts, :run_on_start?, true) do
      send(self(), :sweep)
    else
      schedule(state.interval)
    end

    {:ok, state}
  end

  @impl true
  def handle_info(:sweep, %__MODULE__{} = state) do
    _result = Memory.sweep_expired(state.store, state.opts)
    schedule(state.interval)
    {:noreply, state}
  end

  defp schedule(interval), do: Process.send_after(self(), :sweep, interval)
end
