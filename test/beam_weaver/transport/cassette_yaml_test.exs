defmodule BeamWeaver.Transport.CassetteYamlTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Transport.Cassette
  alias BeamWeaver.Transport.Request

  @moduletag :tmp_dir

  test "a cassette keeps empty strings and lists of integers", %{tmp_dir: dir} do
    path = Path.join(dir, "empty.yml")

    File.write!(path, """
    requests:
    - method: POST
      uri: https://api.example.com/v1/ping
      body: ''
    responses:
    - status: {code: 200, message: OK}
      headers: {content-type: [application/json]}
      body:
        string: '{"codes": [1, 2]}'
    """)

    assert {:ok, cassette} = Cassette.load(path)
    request = Request.new(method: :post, url: "https://api.example.com/v1/ping", body: "")
    assert {:ok, response} = Cassette.match(cassette, request)
    assert response.status == 200
  end

  test "a cassette that isn't valid YAML is an error, not an exception", %{tmp_dir: dir} do
    path = Path.join(dir, "broken.yml")
    File.write!(path, "requests: [unclosed\n  - : :\n")

    assert {:error, %{type: :invalid_cassette}} = Cassette.load(path)
  end
end
