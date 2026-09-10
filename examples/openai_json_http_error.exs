# mix run examples/openai_json_http_error.exs
# A local HTTP server returns an OpenAI-shaped error. No credentials or API calls.

alias BeamWeaver.OpenAI.Client

body =
  BeamWeaver.JSON.encode!(%{
    "error" => %{
      "message" => "Expected an ID that begins with 'fc'",
      "type" => "invalid_request_error",
      "param" => "input[1].id",
      "code" => "invalid_value"
    }
  })

{:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
{:ok, {{127, 0, 0, 1}, port}} = :inet.sockname(listener)

server =
  Task.async(fn ->
    {:ok, socket} = :gen_tcp.accept(listener, 5_000)

    try do
      # Read the complete request before closing the connection after the response.
      receive_request = fn receive_request, buffer ->
        case String.split(buffer, "\r\n\r\n", parts: 2) do
          [headers, request_body] ->
            [_, length] = Regex.run(~r/content-length: (\d+)/i, headers)

            if byte_size(request_body) < String.to_integer(length) do
              {:ok, data} = :gen_tcp.recv(socket, 0, 5_000)
              receive_request.(receive_request, buffer <> data)
            end

          _ ->
            {:ok, data} = :gen_tcp.recv(socket, 0, 5_000)
            receive_request.(receive_request, buffer <> data)
        end
      end

      receive_request.(receive_request, "")

      :ok =
        :gen_tcp.send(
          socket,
          "HTTP/1.1 400 Bad Request\r\ncontent-type: application/json\r\nx-request-id: req_example\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n#{body}"
        )
    after
      :gen_tcp.close(socket)
      :gen_tcp.close(listener)
    end
  end)

try do
  client = Client.new(endpoint: "http://127.0.0.1:#{port}/v1/responses", api_key: "local-fixture")
  {:error, error} = Client.responses(client, %{"model" => "gpt-5.4-mini", "input" => "hello"})
  :http_error = error.type
  400 = error.details.status
  "Expected an ID that begins with 'fc'" = error.message
  "req_example" = error.details.request_id

  IO.inspect(
    %{
      status: error.details.status,
      message: error.message,
      param: error.details.param,
      request_id: error.details.request_id
    },
    label: "Provider error preserved"
  )

  Task.await(server, 5_000)
after
  :gen_tcp.close(listener)
  Task.shutdown(server, :brutal_kill)
end
