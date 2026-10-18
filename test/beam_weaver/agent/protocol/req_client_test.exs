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

  test "req client sends the subagent name and the parent's thread as run metadata, without trace ids" do
    test = self()

    request_fun = fn opts ->
      send(test, {:request_opts, opts})
      {:ok, %{status: 200, body: %{"status" => "ok"}}}
    end

    parent = %{
      thread_id: "ticket-42",
      run_id: "parent-run",
      tool_call_id: "call-1",
      subagent_name: "researcher",
      trace_id: "trace-1",
      trace_run_id: "trace-run-1"
    }

    opts = [request_fun: request_fun, parent: parent]
    metadata = %{subagent_name: "researcher", parent_thread_id: "ticket-42"}

    assert {:ok, _body} =
             ReqClient.start_task(subagent(), %{input: %{messages: []}, metadata: %{team: "billing"}}, opts)

    assert_received {:request_opts, start_opts}
    assert start_opts[:json] == %{input: %{messages: []}, metadata: Map.put(metadata, :team, "billing")}

    assert {:ok, _body} = ReqClient.update_task(subagent(), "task-1", "continue", opts)
    assert_received {:request_opts, update_opts}
    assert update_opts[:json] == %{message: "continue", metadata: metadata}

    assert {:ok, _body} = ReqClient.check_task(subagent(), "task-1", opts)
    assert_received {:request_opts, check_opts}
    assert {:ok, _body} = ReqClient.cancel_task(subagent(), "task-1", opts)
    assert_received {:request_opts, cancel_opts}

    for request <- [start_opts, update_opts, check_opts, cancel_opts] do
      refute Keyword.has_key?(request, :parent)
      refute inspect(request) =~ "trace"
    end

    refute Keyword.has_key?(check_opts, :json)
    refute Keyword.has_key?(cancel_opts, :json)
  end

  test "req client leaves out a parent thread it doesn't have" do
    test = self()

    request_fun = fn opts ->
      send(test, {:request_opts, opts})
      {:ok, %{status: 200, body: %{"status" => "ok"}}}
    end

    parent = %{
      thread_id: nil,
      run_id: nil,
      tool_call_id: "call-1",
      subagent_name: "researcher",
      trace_id: nil,
      trace_run_id: nil
    }

    assert {:ok, _body} = ReqClient.start_task(subagent(), %{input: %{}}, request_fun: request_fun, parent: parent)
    assert_received {:request_opts, opts}
    assert opts[:json] == %{input: %{}, metadata: %{subagent_name: "researcher"}}
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
