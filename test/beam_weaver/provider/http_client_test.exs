defmodule BeamWeaver.Provider.HTTPClientTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Provider.HTTPClient
  alias BeamWeaver.Transport.Request

  describe "transport_opts/3" do
    test "per-call timeout overrides a statically configured transport_opts timeout" do
      client = HTTPClient.new(transport_opts: [timeout: 1_000], timeout: 1_000)
      request = Request.new(method: :post, url: "https://example.com")

      transport_opts = HTTPClient.transport_opts(client, request, timeout: 9_999)

      assert Keyword.get(transport_opts, :timeout) == 9_999
      assert transport_opts[:beam_weaver_http_metadata].timeout_ms == 9_999
    end

    test "falls back to client timeout when no per-call timeout is given" do
      client = HTTPClient.new(transport_opts: [timeout: 1_000], timeout: 4_321)
      request = Request.new(method: :post, url: "https://example.com")

      transport_opts = HTTPClient.transport_opts(client, request, [])

      assert Keyword.get(transport_opts, :timeout) == 4_321
      assert transport_opts[:beam_weaver_http_metadata].timeout_ms == 4_321
    end
  end
end
