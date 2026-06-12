defmodule BeamWeaver.Transport.ReplayTest do
  use ExUnit.Case

  alias BeamWeaver.Transport.Error
  alias BeamWeaver.Transport.Replay
  alias BeamWeaver.Transport.Request
  alias BeamWeaver.Transport.Response

  test "replays a gzipped Python VCR cassette by matching canonical JSON body" do
    cassette_path =
      write_gzip_cassette("""
      requests:
      - body: !!binary |
          eyJoZWxsbyI6IndvcmxkIiwibnVtIjoxfQ==
        headers:
          authorization:
          - '**REDACTED**'
        method: POST
        uri: https://api.example.test/v1/responses
      responses:
      - body:
          string: !!binary |
            eyJvayI6dHJ1ZX0=
        headers:
          content-type:
          - application/json
        status:
          code: 200
          message: OK
      """)

    request =
      Request.new(
        method: :post,
        url: "https://api.example.test/v1/responses",
        headers: [{"authorization", "Bearer sk-test-secret"}],
        json: %{"num" => 1, "hello" => "world"}
      )

    assert {:ok, %Response{status: 200, body: ~s({"ok":true})}} =
             Replay.request(request, cassette_path: cassette_path)
  end

  test "cassette mismatch reports actionable request context without leaking secrets" do
    cassette_path =
      write_gzip_cassette("""
      requests:
      - body: !!binary |
          eyJoZWxsbyI6IndvcmxkIn0=
        headers: {}
        method: POST
        uri: https://api.example.test/v1/responses
      responses:
      - body:
          string: ok
        headers: {}
        status:
          code: 200
          message: OK
      """)

    request =
      Request.new(
        method: :post,
        url: "https://api.example.test/v1/responses",
        json: %{"hello" => "not-world", "api_key" => "plain-secret-should-not-leak"}
      )

    assert {:error, %Error{type: :cassette_mismatch} = error} =
             Replay.request(request, cassette_path: cassette_path)

    details = inspect(error.details)

    assert details =~ "not-world"
    refute details =~ "plain-secret-should-not-leak"
    assert details =~ BeamWeaver.Transport.Redactor.redacted()
  end

  test "missing cassette is a tagged transport error" do
    request = Request.new(method: :get, url: "https://api.example.test")

    assert {:error, %Error{type: :missing_cassette, message: message}} =
             Replay.request(request, cassette_path: "/tmp/beam_weaver_missing_cassette.yaml.gz")

    assert message =~ "cassette not found"
  end

  test "streams replayed successful bodies as deterministic chunks" do
    cassette_path =
      write_gzip_cassette("""
      requests:
      - body: null
        headers: {}
        method: GET
        uri: https://api.example.test/v1/stream
      responses:
      - body:
          string: abcdef
        headers:
          content-type:
          - text/event-stream
        status:
          code: 200
          message: OK
      """)

    request = Request.new(method: :get, url: "https://api.example.test/v1/stream")
    parent = self()

    assert {:ok, %Response{status: 200, body: ""}} =
             Replay.stream(
               request,
               [cassette_path: cassette_path, stream_chunk_size: 2],
               &send(parent, {:chunk, &1})
             )

    assert_received {:chunk, "ab"}
    assert_received {:chunk, "cd"}
    assert_received {:chunk, "ef"}
  end

  test "does not emit replay chunks for non-2xx responses" do
    cassette_path =
      write_gzip_cassette("""
      requests:
      - body: null
        headers: {}
        method: GET
        uri: https://api.example.test/v1/stream
      responses:
      - body:
          string: nope
        headers: {}
        status:
          code: 429
          message: Too Many Requests
      """)

    request = Request.new(method: :get, url: "https://api.example.test/v1/stream")
    parent = self()

    assert {:ok, %Response{status: 429, body: "nope"}} =
             Replay.stream(request, [cassette_path: cassette_path], &send(parent, {:chunk, &1}))

    refute_received {:chunk, _chunk}
  end

  defp write_gzip_cassette(contents) do
    path =
      Path.join([
        System.tmp_dir!(),
        "beam_weaver_replay_#{System.unique_integer([:positive])}.yaml.gz"
      ])

    File.write!(path, :zlib.gzip(contents))
    on_exit(fn -> File.rm(path) end)
    path
  end
end
