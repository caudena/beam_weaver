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
               resolve?: true,
               resolver: resolver
             )

    assert calls(agent) == ["https://start.example/path", "https://final.example/done"]
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
