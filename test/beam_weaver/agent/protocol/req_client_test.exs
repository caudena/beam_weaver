defmodule BeamWeaver.Agent.Protocol.ReqClientTest do
  use ExUnit.Case, async: true

  alias BeamWeaver.Agent.Protocol.ReqClient
  alias BeamWeaver.Agent.Subagent.AsyncSpec

  defp subagent do
    AsyncSpec.new(
      name: "researcher",
      graph_id: "graph-1",
      url: "https://agent.test/api/",
      headers: %{"authorization" => "Bearer token"}
    )
  end

  test "req client encodes async task path segments and normalizes JSON bodies" do
    parent = self()

    request_fun = fn opts ->
      send(parent, {:request_opts, opts})
      {:ok, %{status: 200, body: ~s({"id":"task/with spaces","status":"running"})}}
    end

    assert {:ok, %{"id" => "task/with spaces", "status" => "running"}} =
             ReqClient.check_task(subagent(), "task/with spaces", request_fun: request_fun)

    assert_received {:request_opts, opts}
    assert opts[:method] == :get
    assert opts[:url] == "https://agent.test/api/runs/task%2Fwith%20spaces"
    assert opts[:headers] == %{"authorization" => "Bearer token"}
  end

  test "req client sends start update and cancel request shapes through injected request function" do
    parent = self()

    request_fun = fn opts ->
      send(parent, {:request_opts, opts})
      {:ok, %{status: 200, body: %{"status" => "ok"}}}
    end

    assert {:ok, %{"status" => "ok"}} =
             ReqClient.start_task(subagent(), %{input: %{messages: []}}, request_fun: request_fun)

    assert_received {:request_opts, start_opts}
    assert start_opts[:method] == :post
    assert start_opts[:url] == "https://agent.test/api/runs"
    assert start_opts[:json] == %{input: %{messages: []}}

    assert {:ok, %{"status" => "ok"}} =
             ReqClient.update_task(subagent(), "task/1", "continue", request_fun: request_fun)

    assert_received {:request_opts, update_opts}
    assert update_opts[:url] == "https://agent.test/api/runs/task%2F1/input"
    assert update_opts[:json] == %{message: "continue"}

    assert {:ok, %{"status" => "ok"}} =
             ReqClient.cancel_task(subagent(), "task/1", request_fun: request_fun)

    assert_received {:request_opts, cancel_opts}
    assert cancel_opts[:url] == "https://agent.test/api/runs/task%2F1/cancel"
  end

  test "req client normalizes terminal HTTP rejections without raising on body shape" do
    request_fun = fn _opts ->
      {:ok, %{status: 409, body: ~s({"error":"busy","status":"conflict"})}}
    end

    assert {:error, %{status: 409, body: %{"error" => "busy", "status" => "conflict"}}} =
             ReqClient.check_task(subagent(), "task-1", request_fun: request_fun)

    request_fun = fn _opts -> {:ok, %{status: 500, body: "not json"}} end

    assert {:error, %{status: 500, body: %{"body" => "not json"}}} =
             ReqClient.check_task(subagent(), "task-1", request_fun: request_fun)
  end
end
