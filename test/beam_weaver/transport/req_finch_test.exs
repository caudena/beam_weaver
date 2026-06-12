defmodule BeamWeaver.Transport.ReqFinchTest do
  use ExUnit.Case

  alias BeamWeaver.Transport.Error
  alias BeamWeaver.Transport.ReqFinch
  alias BeamWeaver.Transport.Request
  alias BeamWeaver.Transport.Response

  test "preserves live HTTP responses for successful and non-2xx statuses" do
    cases = [
      {"HTTP/1.1 200 OK\r\ncontent-length: 2\r\nconnection: close\r\n\r\nok", 200, "ok"},
      {"HTTP/1.1 500 Internal Server Error\r\ncontent-length: 4\r\n\r\nfail", 500, "fail"}
    ]

    for {raw_response, status, body} <- cases do
      url = start_http_server(raw_response)
      request = Request.new(method: :get, url: url)

      assert {:ok, %Response{status: ^status, body: ^body}} =
               ReqFinch.request(request, timeout: 1_000)
    end
  end

  test "returns a tagged error when the live transport cannot connect" do
    url = "http://127.0.0.1:#{closed_port()}/unreachable"
    request = Request.new(method: :get, url: url)

    assert {:error, %Error{type: :transport_failure}} = ReqFinch.request(request, timeout: 100)
  end

  test "returns a tagged error when the live transport times out" do
    url = start_silent_http_server()
    request = Request.new(method: :get, url: url)

    assert {:error, %Error{type: :transport_failure}} = ReqFinch.request(request, timeout: 50)
  end

  test "attaches BeamWeaver provider metadata to Finch telemetry" do
    handler_id = "req-finch-provider-metadata-#{System.unique_integer([:positive])}"
    parent = self()

    :telemetry.attach(
      handler_id,
      [:finch, :request, :stop],
      &__MODULE__.handle_finch_telemetry/4,
      parent
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    url = start_http_server("HTTP/1.1 200 OK\r\ncontent-length: 2\r\nconnection: close\r\n\r\nok")

    request =
      Request.new(
        method: :post,
        url: url,
        headers: [{"authorization", "Bearer secret"}],
        json: %{"messages" => [%{"role" => "user", "content" => "hello"}]}
      )

    provider_metadata = %{
      provider: :moonshot,
      url: url,
      timeout_ms: 1_000,
      request_body_summary: %{messages_count: 1}
    }

    assert {:ok, %Response{status: 200}} =
             ReqFinch.request(request,
               timeout: 1_000,
               beam_weaver_http_metadata: provider_metadata
             )

    assert_receive {:finch_telemetry, [:finch, :request, :stop], %{duration: duration},
                    %{request: %Finch.Request{private: %{beam_weaver: ^provider_metadata}}}}

    assert is_integer(duration)
  end

  test "streams successful response chunks before the response completes" do
    parent = self()

    url =
      start_streaming_http_server(fn socket ->
        :ok =
          :gen_tcp.send(
            socket,
            "HTTP/1.1 200 OK\r\ncontent-length: 5\r\nconnection: close\r\n\r\nhe"
          )

        Process.sleep(100)
        :ok = :gen_tcp.send(socket, "llo")
      end)

    request = Request.new(method: :get, url: url)

    task =
      Task.async(fn ->
        ReqFinch.stream(request, [timeout: 1_000], fn chunk ->
          send(parent, {:chunk, chunk})
        end)
      end)

    assert_receive {:chunk, "he"}, 500
    refute Task.yield(task, 0)
    assert {:ok, {:ok, %Response{status: 200, body: ""}}} = Task.yield(task, 1_000)
  end

  test "buffers non-2xx stream bodies without emitting chunks" do
    parent = self()

    url =
      start_streaming_http_server(fn socket ->
        :ok =
          :gen_tcp.send(
            socket,
            "HTTP/1.1 500 Internal Server Error\r\ncontent-length: 4\r\nconnection: close\r\n\r\nfa"
          )

        Process.sleep(50)
        :ok = :gen_tcp.send(socket, "il")
      end)

    request = Request.new(method: :get, url: url)

    assert {:ok, %Response{status: 500, body: "fail"}} =
             ReqFinch.stream(request, [timeout: 1_000], fn chunk ->
               send(parent, {:chunk, chunk})
             end)

    refute_received {:chunk, _chunk}
  end

  test "returns a tagged error when a live stream times out" do
    url = start_silent_http_server()
    request = Request.new(method: :get, url: url)

    assert {:error, %Error{type: :transport_failure}} =
             ReqFinch.stream(request, [timeout: 50], fn _chunk -> :ok end)
  end

  defp start_http_server(response) do
    {:ok, listen_socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, {_address, port}} = :inet.sockname(listen_socket)

    server =
      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listen_socket)
        {:ok, _request} = :gen_tcp.recv(socket, 0, 1_000)
        :ok = :gen_tcp.send(socket, response)
        :gen_tcp.close(socket)
        :gen_tcp.close(listen_socket)
      end)

    on_exit(fn ->
      close_socket(listen_socket)
      stop_server(server)
    end)

    "http://127.0.0.1:#{port}/test"
  end

  defp start_streaming_http_server(fun) do
    {:ok, listen_socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, {_address, port}} = :inet.sockname(listen_socket)

    server =
      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listen_socket)
        {:ok, _request} = :gen_tcp.recv(socket, 0, 1_000)
        fun.(socket)
        :gen_tcp.close(socket)
        :gen_tcp.close(listen_socket)
      end)

    on_exit(fn ->
      close_socket(listen_socket)
      stop_server(server)
    end)

    "http://127.0.0.1:#{port}/stream"
  end

  defp start_silent_http_server do
    {:ok, listen_socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, {_address, port}} = :inet.sockname(listen_socket)

    server =
      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listen_socket)
        {:ok, _request} = :gen_tcp.recv(socket, 0, 1_000)
        Process.sleep(5_000)
        :gen_tcp.close(socket)
        :gen_tcp.close(listen_socket)
      end)

    on_exit(fn ->
      close_socket(listen_socket)
      stop_server(server)
    end)

    "http://127.0.0.1:#{port}/timeout"
  end

  defp closed_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, {_address, port}} = :inet.sockname(socket)
    :gen_tcp.close(socket)
    port
  end

  defp close_socket(socket) do
    :gen_tcp.close(socket)
  catch
    :exit, _reason -> :ok
  end

  defp stop_server(server) do
    if Process.alive?(server), do: Process.exit(server, :kill)
  end

  def handle_finch_telemetry(event, measurements, metadata, parent) do
    send(parent, {:finch_telemetry, event, measurements, metadata})
  end
end
