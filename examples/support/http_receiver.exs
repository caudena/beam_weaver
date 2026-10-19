defmodule BeamWeaver.Examples.HTTPReceiver do
  @moduledoc false

  # A one-request local fixture. It neither forwards nor persists payloads.
  def start(response \\ %{}) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :http_bin, ip: {127, 0, 0, 1}, reuseaddr: true])

    {:ok, {_address, port}} = :inet.sockname(listener)

    task =
      Task.async(fn ->
        try do
          {:ok, socket} = :gen_tcp.accept(listener, 10_000)

          try do
            {:ok, {:http_request, method, {:abs_path, path}, _version}} = :gen_tcp.recv(socket, 0, 10_000)
            headers = headers(socket, %{})
            :ok = :inet.setopts(socket, packet: :raw)
            size = String.to_integer(Map.fetch!(headers, "content-length"))
            {:ok, body} = :gen_tcp.recv(socket, size, 10_000)

            response = BeamWeaver.JSON.encode!(response)

            :ok =
              :gen_tcp.send(
                socket,
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{byte_size(response)}\r\nConnection: close\r\n\r\n" <>
                  response
              )

            %{method: method, path: path, headers: headers, body: BeamWeaver.JSON.decode!(body)}
          after
            :gen_tcp.close(socket)
          end
        after
          :gen_tcp.close(listener)
        end
      end)

    {"http://127.0.0.1:#{port}", task}
  end

  defp headers(socket, headers) do
    case :gen_tcp.recv(socket, 0, 10_000) do
      {:ok, :http_eoh} ->
        headers

      {:ok, {:http_header, _index, name, _reserved, value}} ->
        headers(socket, Map.put(headers, name |> to_string() |> String.downcase(), value))
    end
  end
end
