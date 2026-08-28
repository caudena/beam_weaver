defmodule BeamWeaver.Transport.SafeTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Transport.Error
  alias BeamWeaver.Transport.Request
  alias BeamWeaver.Transport.Response
  alias BeamWeaver.Transport.Safe

  defmodule FakeTransport do
    @behaviour BeamWeaver.Transport

    @impl true
    def request(%Request{} = request, opts) do
      agent = Keyword.fetch!(opts, :agent)

      Agent.get_and_update(agent, fn state ->
        {[response | rest], calls} = state
        {response, {rest, calls ++ [request.url]}}
      end)
      |> to_response()
    end

    defp to_response({:ok, status, body}),
      do: {:ok, Response.new(status: status, body: body)}

    defp to_response({:redirect, location}),
      do: {:ok, Response.new(status: 302, headers: [{"location", location}])}
  end

  defmodule StreamFakeTransport do
    @behaviour BeamWeaver.Transport

    @impl true
    def request(_request, _opts), do: raise("unused")

    @impl true
    def stream(_request, _opts, _on_chunk), do: raise("unused")

    @impl true
    def stream_reduce(%Request{} = request, opts, acc, reducer) do
      agent = Keyword.fetch!(opts, :agent)

      response =
        Agent.get_and_update(agent, fn state ->
          {[entry | rest], calls} = state
          {entry, {rest, calls ++ [request.url]}}
        end)

      case response do
        {:redirect, location} ->
          # Redirect responses never feed the reducer; acc is unchanged.
          {:ok, Response.new(status: 302, headers: [{"location", location}]), acc}

        {:ok, status, chunks} ->
          final = Enum.reduce(chunks, acc, fn chunk, a -> reducer.(a, chunk) end)
          {:ok, Response.new(status: status, body: ""), final}
      end
    end
  end

  defmodule PinTransport do
    @behaviour BeamWeaver.Transport

    @impl true
    def request(request, opts) do
      send(Keyword.fetch!(opts, :observer), {:pinned_request, request, opts})

      {:ok,
       Response.new(
         status: 200,
         body: "ok",
         headers: Keyword.get(opts, :test_headers, [])
       )}
    end
  end

  defmodule ErrorTransport do
    @behaviour BeamWeaver.Transport

    @impl true
    def request(_request, _opts),
      do:
        {:error,
         Error.new(:transport_failure, "synthetic transport failure", %{
           stage: :pre_dispatch,
           bytes_written: 0
         })}
  end

  defmodule RedirectHeaderTransport do
    @behaviour BeamWeaver.Transport

    @impl true
    def request(%Request{} = request, opts) do
      send(Keyword.fetch!(opts, :observer), {:redirect_wire_request, request})
      agent = Keyword.fetch!(opts, :agent)

      Agent.get_and_update(agent, fn
        :redirect ->
          {{:ok,
            Response.new(
              status: 302,
              headers: [{"location", "https://final.example/done"}]
            )}, :done}

        :done ->
          {{:ok, Response.new(status: 200, body: "done")}, :done}
      end)
    end
  end

  test "blocks unsafe initial URLs before delegate transport I/O" do
    {:ok, agent} = start_agent([{:ok, 200, "ok"}])

    assert {:error, %Error{type: :unsafe_url}} =
             Safe.request(
               Request.new(method: :get, url: "https://127.0.0.1/secret"),
               transport: FakeTransport,
               agent: agent
             )

    assert calls(agent) == []
  end

  test "runs dispatch evidence only after request validation and before delegate I/O" do
    callback = fn ->
      send(self(), :dispatch_evidence)
      :ok
    end

    assert {:error, %Error{type: :unsafe_url}} =
             Safe.request(
               Request.new(method: :get, url: "https://127.0.0.1/secret"),
               transport: PinTransport,
               observer: self(),
               before_dispatch: callback
             )

    refute_receive :dispatch_evidence
    refute_receive {:pinned_request, _request, _opts}

    assert {:ok, %Response{status: 200}} =
             Safe.request(
               Request.new(method: :get, url: "https://public.example/path"),
               transport: PinTransport,
               observer: self(),
               resolve?: true,
               pin_resolved?: true,
               resolver: fn _, _ -> {:ok, [{93, 184, 216, 34}]} end,
               before_dispatch: callback
             )

    assert_receive :dispatch_evidence
    assert_receive {:pinned_request, _request, opts}
    refute Keyword.has_key?(opts, :before_dispatch)
  end

  test "streaming returns a typed pre-dispatch error when dispatch evidence fails" do
    assert {:error, %Error{type: :dispatch_evidence_failed}, []} =
             Safe.stream_reduce(
               Request.new(method: :get, url: "https://public.example/path"),
               [
                 transport: PinTransport,
                 observer: self(),
                 before_dispatch: fn -> {:error, :unavailable} end
               ],
               [],
               fn acc, chunk -> [chunk | acc] end
             )

    refute_receive {:pinned_request, _request, _opts}
  end

  test "pins the transport to the validated address while retaining TLS and Host identity" do
    resolver = fn "public.example", 443 -> {:ok, [{93, 184, 216, 34}]} end

    assert {:ok,
            %Response{
              metadata: %{
                requested_host: "public.example",
                connected_address: {93, 184, 216, 34},
                resolved_addresses: [{93, 184, 216, 34}],
                peer_evidence: :response_from_pinned_literal,
                write_evidence: :response_observed
              }
            }} =
             Safe.request(
               Request.new(method: :get, url: "https://public.example/path?q=1"),
               transport: PinTransport,
               observer: self(),
               resolve?: true,
               pin_resolved?: true,
               resolver: resolver
             )

    assert_receive {:pinned_request, request, opts}
    assert request.url == "https://93.184.216.34/path?q=1"
    assert {"host", "public.example"} in request.headers
    assert opts[:connect_options][:hostname] == "public.example"
    assert opts[:connect_options][:protocols] == [:http1]
    assert opts[:mint_connect_options][:max_header_list_size] == 65_536
    assert opts[:raw_response?]
    assert opts[:stream_idle_timeout] == 15_000
    assert opts[:total_timeout] == 15_000
  end

  test "brackets an IPv6 literal in the Host authority" do
    address = {0x2606, 0x4700, 0x4700, 0, 0, 0, 0, 0x1111}

    assert {:ok, %Response{status: 200}} =
             Safe.request(
               Request.new(method: :get, url: "https://[2606:4700:4700::1111]/path"),
               transport: PinTransport,
               observer: self(),
               resolve?: true,
               pin_resolved?: true
             )

    assert_receive {:pinned_request, request, _opts}
    assert request.url == "https://[2606:4700:4700::1111]/path"
    assert {"host", "[2606:4700:4700::1111]"} in request.headers

    assert address ==
             request.url
             |> URI.parse()
             |> Map.fetch!(:host)
             |> String.to_charlist()
             |> then(&:inet.parse_address/1)
             |> elem(1)
  end

  test "passes distinct connect, stream-idle, and total timeouts to the transport" do
    resolver = fn "public.example", 443 -> {:ok, [{93, 184, 216, 34}]} end

    assert {:ok, %Response{status: 200}} =
             Safe.request(
               Request.new(method: :get, url: "https://public.example/path"),
               transport: PinTransport,
               observer: self(),
               resolve?: true,
               pin_resolved?: true,
               resolver: resolver,
               connect_timeout: 500,
               stream_idle_timeout: 1_000,
               total_timeout: 2_000
             )

    assert_receive {:pinned_request, _request, opts}
    assert opts[:connect_options][:timeout] == 500
    assert opts[:stream_idle_timeout] == 1_000
    assert opts[:total_timeout] == 2_000
  end

  test "rejects malformed or oversized request headers before delegate transport I/O" do
    resolver = fn _, _ -> {:ok, [{93, 184, 216, 34}]} end

    for {headers, expected_type} <- [
          {[{"x-test", "safe\r\ninjected: true"}], :invalid_request_headers},
          {[{"x-test", "large"}], :request_headers_too_large}
        ] do
      assert {:error,
              %Error{
                type: ^expected_type,
                details: %{stage: :pre_dispatch, bytes_written: 0}
              }} =
               Safe.request(
                 Request.new(method: :get, url: "https://public.example/path", headers: headers),
                 transport: PinTransport,
                 observer: self(),
                 resolve?: true,
                 pin_resolved?: true,
                 resolver: resolver,
                 max_request_header_bytes: 4
               )
    end

    refute_receive {:pinned_request, _request, _opts}
  end

  test "classifies delegate transport failure as an ambiguous post-dispatch outcome" do
    assert {:error,
            %Error{
              type: :transport_failure,
              details: %{stage: :post_dispatch_unknown, bytes_written: :unknown}
            }} =
             Safe.request(
               Request.new(method: :get, url: "https://public.example/path"),
               transport: ErrorTransport
             )
  end

  test "rejects the complete DNS answer set when any candidate is blocked" do
    resolver = fn "public.example", 443 ->
      {:ok, [{93, 184, 216, 34}, {127, 0, 0, 1}]}
    end

    assert {:error, %Error{type: :unsafe_url}} =
             Safe.request(
               Request.new(method: :get, url: "https://public.example/path"),
               transport: PinTransport,
               observer: self(),
               resolve?: true,
               pin_resolved?: true,
               resolver: resolver
             )

    refute_receive {:pinned_request, _request, _opts}
  end

  test "rejects oversized response headers before accepting a response" do
    assert {:error, %Error{type: :response_headers_too_large}} =
             Safe.request(
               Request.new(method: :get, url: "https://public.example/path"),
               transport: PinTransport,
               observer: self(),
               resolve?: true,
               pin_resolved?: true,
               resolver: fn _, _ -> {:ok, [{93, 184, 216, 34}]} end,
               test_headers: [{"content-type", "text/plain"}],
               max_response_header_bytes: 1
             )
  end

  test "follows safe redirects through the same URL policy" do
    {:ok, agent} =
      start_agent([
        {:redirect, "https://final.example/done"},
        {:ok, 200, "done"}
      ])

    resolver =
      resolver(%{
        "start.example" => [{93, 184, 216, 34}],
        "final.example" => [{93, 184, 216, 35}]
      })

    assert {:ok, %Response{status: 200, body: "done"}} =
             Safe.request(
               Request.new(method: :get, url: "https://start.example/path"),
               transport: FakeTransport,
               agent: agent,
               follow_redirects?: true,
               resolve?: true,
               resolver: resolver
             )

    assert calls(agent) == ["https://start.example/path", "https://final.example/done"]
  end

  test "does not forward credentials or arbitrary headers across redirect origins" do
    {:ok, agent} = Agent.start_link(fn -> :redirect end)

    request =
      Request.new(
        method: :post,
        url: "https://start.example/path",
        headers: [
          {"authorization", "Bearer secret"},
          {"x-provider-secret", "secret"},
          {"content-type", "application/json"}
        ],
        body: "{}"
      )

    assert {:ok, %Response{status: 200}} =
             Safe.request(request,
               transport: RedirectHeaderTransport,
               observer: self(),
               agent: agent,
               follow_redirects?: true
             )

    assert_receive {:redirect_wire_request, first}
    assert {"authorization", "Bearer secret"} in first.headers
    assert_receive {:redirect_wire_request, second}
    assert second.url == "https://final.example/done"
    assert second.headers == [{"content-type", "application/json"}]
  end

  test "blocks redirects that resolve to private or metadata addresses" do
    {:ok, agent} = start_agent([{:redirect, "https://private.example/pwned"}])

    resolver =
      resolver(%{
        "start.example" => [{93, 184, 216, 34}],
        "private.example" => [{127, 0, 0, 1}]
      })

    assert {:error, %Error{type: :unsafe_url, message: "DNS resolution produced a blocked address"}} =
             Safe.request(
               Request.new(method: :get, url: "https://start.example/path"),
               transport: FakeTransport,
               agent: agent,
               follow_redirects?: true,
               resolve?: true,
               resolver: resolver
             )

    assert calls(agent) == ["https://start.example/path"]
  end

  test "keeps redirect responses when following is disabled" do
    {:ok, agent} = start_agent([{:redirect, "https://final.example/done"}])

    assert {:ok, %Response{status: 302}} =
             Safe.request(
               Request.new(method: :get, url: "https://start.example/path"),
               transport: FakeTransport,
               agent: agent,
               follow_redirects?: false
             )

    assert calls(agent) == ["https://start.example/path"]
  end

  test "keeps redirect responses by default" do
    {:ok, agent} = start_agent([{:redirect, "https://final.example/done"}])

    assert {:ok, %Response{status: 302}} =
             Safe.request(
               Request.new(method: :get, url: "https://start.example/path"),
               transport: FakeTransport,
               agent: agent
             )

    assert calls(agent) == ["https://start.example/path"]
  end

  test "stream_reduce blocks unsafe initial URLs before delegate transport I/O" do
    {:ok, agent} = start_agent([{:ok, 200, ["chunk"]}])

    assert {:error, %Error{type: :unsafe_url}, :acc} =
             Safe.stream_reduce(
               Request.new(method: :get, url: "https://127.0.0.1/secret"),
               [transport: StreamFakeTransport, agent: agent],
               :acc,
               fn acc, chunk -> [chunk | List.wrap(acc)] end
             )

    assert calls(agent) == []
  end

  test "stream_reduce follows safe redirects through the same URL policy" do
    {:ok, agent} =
      start_agent([
        {:redirect, "https://final.example/done"},
        {:ok, 200, ["a", "b"]}
      ])

    resolver =
      resolver(%{
        "start.example" => [{93, 184, 216, 34}],
        "final.example" => [{93, 184, 216, 35}]
      })

    assert {:ok, %Response{status: 200}, ["b", "a"]} =
             Safe.stream_reduce(
               Request.new(method: :get, url: "https://start.example/path"),
               [
                 transport: StreamFakeTransport,
                 agent: agent,
                 follow_redirects?: true,
                 resolve?: true,
                 resolver: resolver
               ],
               [],
               fn acc, chunk -> [chunk | acc] end
             )

    assert calls(agent) == ["https://start.example/path", "https://final.example/done"]
  end

  test "stream_reduce blocks redirects that resolve to private or metadata addresses" do
    {:ok, agent} = start_agent([{:redirect, "https://private.example/pwned"}])

    resolver =
      resolver(%{
        "start.example" => [{93, 184, 216, 34}],
        "private.example" => [{169, 254, 169, 254}]
      })

    assert {:error, %Error{type: :unsafe_url}, []} =
             Safe.stream_reduce(
               Request.new(method: :get, url: "https://start.example/path"),
               [
                 transport: StreamFakeTransport,
                 agent: agent,
                 follow_redirects?: true,
                 resolve?: true,
                 resolver: resolver
               ],
               [],
               fn acc, chunk -> [chunk | acc] end
             )

    assert calls(agent) == ["https://start.example/path"]
  end

  test "stream/3 unwraps the redirect-validated streaming response" do
    {:ok, agent} =
      start_agent([
        {:redirect, "https://final.example/done"},
        {:ok, 200, ["x"]}
      ])

    resolver =
      resolver(%{
        "start.example" => [{93, 184, 216, 34}],
        "final.example" => [{93, 184, 216, 35}]
      })

    {:ok, collector} = Agent.start_link(fn -> [] end)

    assert {:ok, %Response{status: 200}} =
             Safe.stream(
               Request.new(method: :get, url: "https://start.example/path"),
               [
                 transport: StreamFakeTransport,
                 agent: agent,
                 follow_redirects?: true,
                 resolve?: true,
                 resolver: resolver
               ],
               fn chunk -> Agent.update(collector, &[chunk | &1]) end
             )

    assert Agent.get(collector, & &1) == ["x"]
    assert calls(agent) == ["https://start.example/path", "https://final.example/done"]
  end

  defp start_agent(responses), do: Agent.start_link(fn -> {responses, []} end)

  defp calls(agent), do: Agent.get(agent, fn {_responses, calls} -> calls end)

  defp resolver(hosts) do
    fn host, _port ->
      case Map.fetch(hosts, host) do
        {:ok, addresses} -> {:ok, addresses}
        :error -> {:error, :nxdomain}
      end
    end
  end
end
