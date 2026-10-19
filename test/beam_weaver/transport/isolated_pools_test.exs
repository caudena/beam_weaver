defmodule BeamWeaver.Transport.IsolatedPoolsTest do
  # These requests share the application's pools, and the atom and pool
  # counts below are global, so nothing else may run alongside.
  use ExUnit.Case, async: false

  import BeamWeaver.TestSupport.Eventually

  alias BeamWeaver.Transport.Error
  alias BeamWeaver.Transport.IsolatedPools
  alias BeamWeaver.Transport.ReqFinch
  alias BeamWeaver.Transport.Request
  alias BeamWeaver.Transport.Response
  alias BeamWeaver.Transport.Safe

  @server __MODULE__.Server
  @finch __MODULE__.Finch
  @shared_finch BeamWeaver.Transport.Finch
  @ipv6_loopback {0, 0, 0, 0, 0, 0, 0, 1}

  # Hosts without IPv6, such as some containers, skip the IPv6 tests.
  @no_ipv6_loopback (case :gen_tcp.listen(0, [:inet6, ip: @ipv6_loopback]) do
                       {:ok, socket} ->
                         :ok = :gen_tcp.close(socket)
                         nil

                       {:error, reason} ->
                         "this host has no IPv6 loopback: #{inspect(reason)}"
                     end)

  describe "unpinned requests through Transport.Safe" do
    test "many origins share a bounded set of pools and never reach the shared pool" do
      max_pools = IsolatedPools.snapshot().max_pools
      shared_pools = live_pools(@shared_finch)
      req_instances = req_finch_instances()

      # A port per origin: unpinned requests connect to the host they name.
      for port <- Enum.map(1..(max_pools + 24), fn _ -> start_server() end) do
        assert {:ok, %Response{status: 200, body: body}} =
                 Safe.request(Request.new(method: :get, url: "http://127.0.0.1:#{port}/page"),
                   url_policy: [schemes: ["http"], allow_localhost?: true]
                 )

        assert body == "127.0.0.1:#{port}"
      end

      assert live_pools(@shared_finch) == shared_pools
      assert req_finch_instances() == req_instances
      assert live_pools(finch()) <= max_pools
      assert length(IsolatedPools.snapshot().pools) <= max_pools
    end
  end

  describe "provider requests" do
    test "stay on the shared pool" do
      port = start_server()

      assert {:ok, %Response{status: 200}} =
               ReqFinch.request(Request.new(method: :get, url: "http://127.0.0.1:#{port}/page"), timeout: 1_000)

      assert {:ok, _pid} = Finch.find_pool(@shared_finch, %Finch.Pool{scheme: :http, host: "127.0.0.1", port: port})
      assert pools_for_port(port) == []
    end
  end

  describe "IPv6 addresses" do
    @describetag skip: @no_ipv6_loopback

    test "requests and streams to an IPv6 address connect on isolated pools" do
      port = start_server(ip: @ipv6_loopback)
      request = Request.new(method: :get, url: "http://[::1]:#{port}/page")
      authority = "[::1]:#{port}"
      policy = [schemes: ["http"], allow_localhost?: true]
      collect = fn chunks, chunk -> [chunk | chunks] end

      assert {:ok, %Response{status: 200, body: ^authority}} = ReqFinch.request(request, timeout: 1_000)

      assert {:ok, %Response{status: 200}} = ReqFinch.stream(request, [timeout: 1_000], &send(self(), {:chunk, &1}))
      assert received_body() == authority

      assert {:ok, %Response{status: 200}, chunks} = ReqFinch.stream_reduce(request, [timeout: 1_000], [], collect)
      assert body(chunks) == authority

      assert {:ok, %Response{status: 200, body: ^authority}} = Safe.request(request, url_policy: policy)

      assert {:ok, %Response{status: 200}, chunks} = Safe.stream_reduce(request, [url_policy: policy], [], collect)
      assert body(chunks) == authority

      assert Finch.find_pool(@shared_finch, %Finch.Pool{scheme: :http, host: "::1", port: port}) == :error
      assert [_pool | _pools] = pools_for_port(port)
    end

    test "a request pinned to an IPv6 address connects" do
      port = start_server(ip: @ipv6_loopback)
      resolver = fn "v6.example", ^port -> {:ok, [@ipv6_loopback]} end

      assert {:ok, %Response{status: 200, body: body, metadata: %{connected_address: @ipv6_loopback}}} =
               Safe.request(Request.new(method: :get, url: "http://v6.example:#{port}/page"),
                 url_policy: Keyword.put(policy(), :resolver, resolver)
               )

      assert body == "v6.example:#{port}"
    end
  end

  describe "pinned requests through Transport.Safe" do
    test "many hosts share a bounded set of pools and create no atoms" do
      port = start_server()
      max_pools = IsolatedPools.snapshot().max_pools

      # Warm up past the limit, so the measured hosts below also evict pools.
      for i <- 1..(max_pools + 2), do: assert({:ok, %Response{status: 200}} = fetch("warm-#{i}.example", port))

      req_instances = req_finch_instances()
      atoms = :erlang.system_info(:atom_count)

      for i <- 1..40 do
        host = "site-#{i}.example"
        assert {:ok, %Response{status: 200, body: body}} = fetch(host, port)
        assert body == "#{host}:#{port}"
      end

      # Req named a new Finch instance for every host: nine atoms each. The
      # margin only allows for code loaded by other processes meanwhile.
      new_atoms = :erlang.system_info(:atom_count) - atoms
      assert new_atoms < 10, "40 hosts created #{new_atoms} atoms"
      assert req_finch_instances() == req_instances
      assert live_pools() <= max_pools
      assert length(IsolatedPools.snapshot().pools) <= max_pools
    end

    test "repeated requests to one host reuse its pool" do
      port = start_server()
      req_instances = req_finch_instances()

      assert {:ok, %Response{status: 200}} = fetch("same.example", port)
      assert req_finch_instances() == req_instances
      assert [%{pool: pool, leases: 0}] = pools_for("same.example", port)
      assert {:ok, pid} = Finch.find_pool(finch(), pool)

      for _ <- 1..4, do: assert({:ok, %Response{status: 200}} = fetch("same.example", port))

      assert [%{pool: ^pool, leases: 0}] = pools_for("same.example", port)
      assert {:ok, ^pid} = Finch.find_pool(finch(), pool)
      assert req_finch_instances() == req_instances
    end

    test "a stream in flight keeps its pool while requests to other hosts evict the rest" do
      port = start_server(hold: "held.example")
      req_instances = req_finch_instances()
      max_pools = IsolatedPools.snapshot().max_pools

      task =
        Task.async(fn ->
          Safe.stream_reduce(
            Request.new(method: :get, url: "http://held.example:#{port}/page"),
            [url_policy: policy()],
            [],
            fn chunks, chunk -> [chunk | chunks] end
          )
        end)

      assert_receive {:holding, server}, 5_000
      assert req_finch_instances() == req_instances
      assert [%{pool: held_pool, leases: 1}] = pools_for("held.example", port)
      assert {:ok, held_pid} = Finch.find_pool(finch(), held_pool)

      for i <- 1..(2 * max_pools) do
        host = "pressure-#{i}.example"
        assert {:ok, %Response{status: 200, body: body}} = fetch(host, port)
        assert body == "#{host}:#{port}"
      end

      assert req_finch_instances() == req_instances
      assert live_pools() <= max_pools
      assert [%{pool: ^held_pool, leases: 1}] = pools_for("held.example", port)
      assert {:ok, ^held_pid} = Finch.find_pool(finch(), held_pool)

      send(server, :release)
      assert {:ok, %Response{status: 200}, chunks} = Task.await(task, 5_000)
      assert chunks |> Enum.reverse() |> IO.iodata_to_binary() == "first-second"
      assert eventually(fn -> match?([%{leases: 0}], pools_for("held.example", port)) end)
    end

    test "requests that time out or fail release their pools" do
      port = start_server(silent: "silent.example")
      refused_port = closed_port()
      req_instances = req_finch_instances()

      assert {:error, %Error{type: :timeout}} =
               Safe.stream(
                 Request.new(method: :get, url: "http://silent.example:#{port}/page"),
                 [url_policy: Keyword.put(policy(), :timeout, 100)],
                 fn chunk -> flunk("unexpected chunk #{inspect(chunk)}") end
               )

      assert {:error, %Error{type: :transport_failure}} = fetch("refused.example", refused_port)

      assert req_finch_instances() == req_instances
      assert [%{leases: 0}] = pools_for("silent.example", port)
      assert [%{leases: 0}] = pools_for("refused.example", refused_port)
    end
  end

  describe "pool limits" do
    setup context do
      start_supervised!(
        {IsolatedPools,
         name: @server, finch: @finch, max_pools: 2, idle_timeout: Map.get(context, :idle_timeout, 60_000)}
      )

      :ok
    end

    test "a new key replaces the least recently used idle pool" do
      assert {:ok, [name: @finch, pool_tag: _tag], lease_a} = checkout("a.example")
      IsolatedPools.checkin(@server, lease_a)
      assert {:ok, _finch, lease_b} = checkout("b.example")
      IsolatedPools.checkin(@server, lease_b)
      assert [%{pool: pool_a}] = server_pools("a.example")
      assert [%{pool: pool_b}] = server_pools("b.example")

      assert {:ok, _finch, _lease_c} = checkout("c.example")

      assert Finch.find_pool(@finch, pool_a) == :error
      assert {:ok, _pid} = Finch.find_pool(@finch, pool_b)
      assert server_pools("a.example") == []
    end

    test "a new key waits while every pool has a request in flight" do
      assert {:ok, _finch, lease_a} = checkout("a.example")
      assert {:ok, _finch, _lease_b} = checkout("b.example")
      assert [%{pool: pool_a}] = server_pools("a.example")
      assert [%{pool: pool_b}] = server_pools("b.example")

      waiter = Task.async(fn -> checkout("c.example", 5_000) end)
      assert eventually(fn -> IsolatedPools.snapshot(@server).waiting == 1 end)
      refute Task.yield(waiter, 50)

      IsolatedPools.checkin(@server, lease_a)

      assert {:ok, _finch, _lease_c} = Task.await(waiter)
      assert Finch.find_pool(@finch, pool_a) == :error
      assert {:ok, _pid} = Finch.find_pool(@finch, pool_b)
    end

    test "a waiting checkout fails once its timeout passes" do
      assert {:ok, _finch, _lease_a} = checkout("a.example")
      assert {:ok, _finch, _lease_b} = checkout("b.example")

      assert {:error, %Error{type: :transport_failure, details: %{max_isolated_pools: 2}}} =
               checkout("c.example", 50)

      assert IsolatedPools.snapshot(@server).waiting == 0
    end

    test "a lease ends when the process holding it exits" do
      parent = self()

      holder =
        spawn(fn ->
          send(parent, {:leased, checkout("a.example")})
          Process.sleep(:infinity)
        end)

      assert_receive {:leased, {:ok, _finch, _lease}}
      assert {:ok, _finch, _lease_b} = checkout("b.example")

      Process.exit(holder, :kill)

      assert {:ok, _finch, _lease_c} = checkout("c.example", 5_000)
      assert server_pools("a.example") == []
    end

    @tag idle_timeout: 50
    test "an idle pool stops, and its key gets a new tag afterwards" do
      assert {:ok, [name: @finch, pool_tag: first_tag], lease} = checkout("a.example")
      assert [%{pool: pool}] = server_pools("a.example")

      IsolatedPools.checkin(@server, lease)

      assert eventually(fn -> IsolatedPools.snapshot(@server).pools == [] end)
      assert Finch.find_pool(@finch, pool) == :error

      assert {:ok, [name: @finch, pool_tag: second_tag], _lease} = checkout("a.example")
      assert second_tag != first_tag
    end
  end

  defp checkout(host, timeout \\ 1_000) do
    IsolatedPools.checkout(@server, {"http", "127.0.0.1", 8080, [conn_opts: [hostname: host]]}, timeout)
  end

  defp server_pools(host), do: with_hostname(IsolatedPools.snapshot(@server).pools, host)

  defp policy do
    [
      schemes: ["http"],
      allow_localhost?: true,
      resolve?: true,
      pin_resolved?: true,
      resolver: fn _host, _port -> {:ok, [{127, 0, 0, 1}]} end
    ]
  end

  defp fetch(host, port) do
    Safe.request(Request.new(method: :get, url: "http://#{host}:#{port}/page"), url_policy: policy())
  end

  defp finch, do: IsolatedPools.snapshot().finch

  # Only the pools for this test's server: earlier tests leave idle pools.
  defp pools_for(host, port), do: port |> pools_for_port() |> with_hostname(host)

  defp pools_for_port(port) do
    Enum.filter(IsolatedPools.snapshot().pools, &match?(%{key: {_scheme, _address, ^port, _pool_options}}, &1))
  end

  defp with_hostname(pools, host) do
    Enum.filter(pools, fn %{key: {_scheme, _address, _port, pool_options}} ->
      pool_options[:conn_opts][:hostname] == host
    end)
  end

  defp body(chunks), do: chunks |> Enum.reverse() |> IO.iodata_to_binary()

  defp received_body(chunks \\ []) do
    receive do
      {:chunk, chunk} -> received_body([chunk | chunks])
    after
      0 -> body(chunks)
    end
  end

  defp req_finch_instances, do: DynamicSupervisor.count_children(Req.FinchSupervisor).active

  # Every pool a Finch instance runs, including any Finch started on its own
  # for isolated requests, not only the ones the manager tracks.
  defp live_pools(finch \\ finch()) do
    finch
    |> Finch.Pool.Manager.supervisor_name()
    |> DynamicSupervisor.count_children()
    |> Map.fetch!(:active)
  end

  # Answers every connection with the request's Host header as the body. A
  # request for `:hold` gets its first chunk, then waits for `:release`; one
  # for `:silent` gets no answer.
  defp start_server(opts \\ []) do
    parent = self()
    ip = Keyword.get(opts, :ip, {127, 0, 0, 1})
    family = if tuple_size(ip) == 8, do: [:inet6], else: []

    {:ok, listen} = :gen_tcp.listen(0, family ++ [:binary, active: false, reuseaddr: true, ip: ip])
    {:ok, port} = :inet.port(listen)
    acceptor = spawn(fn -> accept(listen, parent, opts) end)

    on_exit(fn ->
      :gen_tcp.close(listen)
      Process.exit(acceptor, :kill)
    end)

    port
  end

  defp accept(listen, parent, opts) do
    with {:ok, socket} <- :gen_tcp.accept(listen) do
      # The handler starts once it owns the socket.
      handler =
        spawn(fn ->
          receive do
            :serve -> serve(socket, parent, opts)
          end
        end)

      _result = :gen_tcp.controlling_process(socket, handler)
      send(handler, :serve)
      accept(listen, parent, opts)
    end
  end

  defp serve(socket, parent, opts) do
    with {:ok, request} <- recv_headers(socket, "") do
      [_request_line | lines] = String.split(request, "\r\n")
      authority = Enum.find_value(lines, fn line -> host_header(line) end)
      host = authority |> String.split(":") |> hd()

      cond do
        host == opts[:hold] ->
          :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\ncontent-length: 12\r\nconnection: close\r\n\r\nfirst-")
          send(parent, {:holding, self()})

          receive do
            :release -> :gen_tcp.send(socket, "second")
          after
            5_000 -> :ok
          end

        host == opts[:silent] ->
          Process.sleep(1_000)

        true ->
          :gen_tcp.send(
            socket,
            "HTTP/1.1 200 OK\r\ncontent-length: #{byte_size(authority)}\r\nconnection: close\r\n\r\n#{authority}"
          )
      end
    end

    :gen_tcp.close(socket)
  end

  defp closed_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp recv_headers(socket, received) do
    if String.contains?(received, "\r\n\r\n") do
      {:ok, received}
    else
      with {:ok, data} <- :gen_tcp.recv(socket, 0, 5_000), do: recv_headers(socket, received <> data)
    end
  end

  defp host_header(line) do
    case String.split(line, ":", parts: 2) do
      [name, value] -> if String.downcase(name) == "host", do: String.trim(value)
      _other -> nil
    end
  end
end
