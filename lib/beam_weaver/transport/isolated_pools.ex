defmodule BeamWeaver.Transport.IsolatedPools do
  @moduledoc false

  # Connection pools for the requests `Transport.ReqFinch` keeps out of the
  # pool provider calls share: requests with connection settings of their own,
  # such as the `:mint_connect_options` every `Transport.Safe` request sets
  # (so URLs from users or models never grow the shared pool), or the IPv6
  # socket a request to an IPv6 address needs.
  #
  # Req would start a Finch instance, named by new atoms, for every distinct
  # set of settings and keep it forever: a process tree and atoms per host.
  # These pools live in one Finch instance instead. Each pool serves one origin
  # with one set of settings under a tag of its own, so a request only shares
  # connections made for the same address, TLS host name and options, and a tag
  # never names a pool with other settings. At most `max_pools` pools exist: a
  # new key stops the least recently used pool with no request in flight, or
  # waits until a request finishes. A pool also stops after `idle_timeout`
  # without requests.

  use GenServer

  alias BeamWeaver.Config
  alias BeamWeaver.Transport.Error

  @default_max_pools 16
  @default_idle_timeout 60_000

  @typedoc "Scheme, host and port of the request URL, and the pool's Finch options."
  @type key :: {String.t(), String.t(), :inet.port_number(), keyword()}

  def child_spec(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    finch = Keyword.get(opts, :finch, BeamWeaver.Transport.IsolatedFinch)

    settings = [
      finch: finch,
      max_pools: setting!(opts, :max_pools, :max_isolated_pools, @default_max_pools),
      idle_timeout: setting!(opts, :idle_timeout, :isolated_pool_idle_timeout, @default_idle_timeout)
    ]

    children = [
      # Requests only reach pools started for their own key. A pool Finch
      # starts by itself, for a lease held across a restart, stops once idle.
      {Finch, name: finch, pools: %{default: [pool_max_idle_time: settings[:idle_timeout]]}},
      %{id: __MODULE__, start: {GenServer, :start_link, [__MODULE__, settings, [name: name]]}}
    ]

    # The pools and their manager restart together, so a restarted manager
    # never finds pools it doesn't know about.
    %{
      id: name,
      type: :supervisor,
      start: {Supervisor, :start_link, [children, [strategy: :one_for_all]]}
    }
  end

  @spec run(String.t(), keyword(), timeout(), (keyword(), timeout() -> result)) ::
          result | {:error, Error.t()}
        when result: term()
  def run(url, pool_options, timeout, fun) when is_function(fun, 2) do
    %URI{scheme: scheme, host: host, port: port} = URI.parse(url)
    started_at = System.monotonic_time(:millisecond)

    with {:ok, finch, lease} <- checkout(__MODULE__, {scheme, host, port, pool_options}, timeout) do
      try do
        fun.(finch, time_left(timeout, started_at))
      after
        checkin(__MODULE__, lease)
      end
    end
  end

  @spec checkout(GenServer.server(), key(), timeout()) ::
          {:ok, keyword(), reference()} | {:error, Error.t()}
  def checkout(server, {_scheme, _host, _port, pool_options} = key, timeout)
      when is_list(pool_options) and (timeout == :infinity or (is_integer(timeout) and timeout >= 0)) do
    GenServer.call(server, {:checkout, key, timeout}, :infinity)
  end

  @spec checkin(GenServer.server(), reference()) :: :ok
  def checkin(server, lease), do: GenServer.cast(server, {:checkin, lease})

  @spec snapshot(GenServer.server()) :: map()
  def snapshot(server \\ __MODULE__), do: GenServer.call(server, :snapshot)

  @impl true
  def init(settings), do: {:ok, settings |> Map.new() |> Map.merge(%{pools: %{}, leases: %{}, waiting: []})}

  @impl true
  def handle_call({:checkout, key, timeout}, {pid, _tag} = from, state) do
    # The monitor reference is the lease, so a caller that exits releases it.
    lease = Process.monitor(pid)

    case grant(state, key, lease) do
      {:ok, finch, state} ->
        {:reply, {:ok, finch, lease}, state}

      {:error, error, state} ->
        Process.demonitor(lease, [:flush])
        {:reply, {:error, error}, state}

      :busy ->
        waiter = %{lease: lease, from: from, key: key, timer: start_timer(timeout, {:waiting, lease})}
        {:noreply, %{state | waiting: state.waiting ++ [waiter]}}
    end
  end

  def handle_call(:snapshot, _from, state) do
    pools = for {key, entry} <- state.pools, do: %{key: key, pool: entry.pool, leases: entry.leases}

    {:reply, %{finch: state.finch, max_pools: state.max_pools, pools: pools, waiting: length(state.waiting)}, state}
  end

  @impl true
  def handle_cast({:checkin, lease}, state), do: {:noreply, release(state, lease)}

  @impl true
  def handle_info({:DOWN, lease, :process, _pid, _reason}, state) do
    if Map.has_key?(state.leases, lease) do
      {:noreply, release(state, lease)}
    else
      {_waiter, state} = pop_waiter(state, lease)
      {:noreply, state}
    end
  end

  def handle_info({:timeout, _timer, {:waiting, lease}}, state) do
    case pop_waiter(state, lease) do
      {nil, state} ->
        {:noreply, state}

      {waiter, state} ->
        Process.demonitor(lease, [:flush])

        GenServer.reply(
          waiter.from,
          {:error,
           Error.new(:transport_failure, "timed out waiting for an isolated connection pool", %{
             max_isolated_pools: state.max_pools
           })}
        )

        {:noreply, state}
    end
  end

  def handle_info({:timeout, timer, {:idle, key}}, state) do
    case state.pools do
      %{^key => %{leases: 0, idle_timer: ^timer}} -> {:noreply, stop_pool(state, key)}
      _pools -> {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp grant(state, key, lease) do
    with {:ok, state} <- ensure_pool(state, key) do
      entry = Map.fetch!(state.pools, key)
      cancel_timer(entry.idle_timer)
      entry = %{entry | leases: entry.leases + 1, idle_timer: nil}

      state = %{state | pools: Map.put(state.pools, key, entry), leases: Map.put(state.leases, lease, key)}
      {:ok, [name: state.finch, pool_tag: entry.pool.tag], state}
    end
  end

  defp ensure_pool(state, key) do
    cond do
      Map.has_key?(state.pools, key) -> {:ok, state}
      map_size(state.pools) < state.max_pools -> start_pool(state, key)
      idle_key = least_recently_used_idle(state.pools) -> state |> stop_pool(idle_key) |> start_pool(key)
      true -> :busy
    end
  end

  defp least_recently_used_idle(pools) do
    pools
    |> Enum.filter(fn {_key, entry} -> entry.leases == 0 end)
    |> Enum.min_by(fn {_key, entry} -> entry.used_at end, fn -> {nil, nil} end)
    |> elem(0)
  end

  # A fresh tag per start: a request holding the tag of a stopped pool can
  # never reach a pool started later for other settings.
  defp start_pool(state, {scheme, host, port, pool_options} = key) do
    pool = %Finch.Pool{scheme: scheme(scheme), host: host, port: port, tag: make_ref()}
    :ok = Finch.start_pool(state.finch, pool, pool_options)

    entry = %{pool: pool, leases: 0, used_at: System.monotonic_time(), idle_timer: nil}
    {:ok, %{state | pools: Map.put(state.pools, key, entry)}}
  rescue
    exception ->
      {:error,
       Error.new(:invalid_transport_options, "could not start an isolated connection pool", %{
         reason: Exception.message(exception)
       }), state}
  catch
    :exit, reason ->
      {:error, Error.new(:transport_failure, "could not start an isolated connection pool", %{reason: inspect(reason)}),
       state}
  end

  defp scheme("http"), do: :http
  defp scheme("https"), do: :https
  defp scheme(other), do: raise(ArgumentError, "unsupported URL scheme: #{inspect(other)}")

  defp stop_pool(state, key) do
    {entry, pools} = Map.pop!(state.pools, key)
    cancel_timer(entry.idle_timer)
    stop_finch_pool(state.finch, entry.pool)
    %{state | pools: pools}
  end

  # A pool that already stopped leaves nothing to stop.
  defp stop_finch_pool(finch, pool) do
    Finch.stop_pool(finch, pool)
  catch
    :exit, _reason -> {:error, :not_found}
  end

  defp release(state, lease) do
    case Map.pop(state.leases, lease) do
      {nil, _leases} ->
        state

      {key, leases} ->
        Process.demonitor(lease, [:flush])
        entry = Map.fetch!(state.pools, key)
        entry = %{entry | leases: entry.leases - 1, used_at: System.monotonic_time()}

        entry =
          if entry.leases == 0,
            do: %{entry | idle_timer: start_timer(state.idle_timeout, {:idle, key})},
            else: entry

        serve_waiting(%{state | leases: leases, pools: Map.put(state.pools, key, entry)})
    end
  end

  # Called whenever a pool loses its last lease: waiters are served in order,
  # and one whose key can't be placed yet keeps its place.
  defp serve_waiting(%{waiting: []} = state), do: state

  defp serve_waiting(%{waiting: waiting} = state) do
    {still_waiting, state} =
      Enum.reduce(waiting, {[], %{state | waiting: []}}, fn waiter, {still_waiting, state} ->
        case grant(state, waiter.key, waiter.lease) do
          {:ok, finch, state} ->
            cancel_timer(waiter.timer)
            GenServer.reply(waiter.from, {:ok, finch, waiter.lease})
            {still_waiting, state}

          {:error, error, state} ->
            cancel_timer(waiter.timer)
            Process.demonitor(waiter.lease, [:flush])
            GenServer.reply(waiter.from, {:error, error})
            {still_waiting, state}

          :busy ->
            {[waiter | still_waiting], state}
        end
      end)

    %{state | waiting: Enum.reverse(still_waiting)}
  end

  defp pop_waiter(state, lease) do
    case Enum.split_with(state.waiting, &(&1.lease == lease)) do
      {[waiter], waiting} ->
        cancel_timer(waiter.timer)
        {waiter, %{state | waiting: waiting}}

      {[], _waiting} ->
        {nil, state}
    end
  end

  defp start_timer(:infinity, _message), do: nil
  defp start_timer(timeout, message), do: :erlang.start_timer(timeout, self(), message)

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer), do: :erlang.cancel_timer(timer, async: true, info: false)

  defp time_left(:infinity, _started_at), do: :infinity

  defp time_left(timeout, started_at),
    do: max(timeout - (System.monotonic_time(:millisecond) - started_at), 0)

  defp setting!(opts, key, config_key, default) do
    case Keyword.get_lazy(opts, key, fn -> Config.get([:transport, config_key], default) end) do
      value when is_integer(value) and value > 0 ->
        value

      value ->
        raise ArgumentError,
              "expected config :beam_weaver, :transport, #{config_key}: to be a positive integer, got: #{inspect(value)}"
    end
  end
end
