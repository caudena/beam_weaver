alias BeamWeaver.Agent.Protocol.ReqClient
alias BeamWeaver.Agent.Subagent.AsyncSpec

subagent =
  AsyncSpec.new(
    name: "remote-researcher",
    description: "Long-running hosted researcher.",
    graph_id: "researcher",
    url: "https://agents.example.test",
    headers: %{"authorization" => "Bearer demo-token"}
  )

request_fun = fn opts ->
  IO.inspect(
    %{
      method: opts[:method],
      url: opts[:url],
      json: opts[:json],
      headers: Map.keys(opts[:headers])
    },
    label: "Agent Protocol request"
  )

  {:ok, %{status: 202, body: ~s({"id":"task-42","status":"running"})}}
end

{:ok, started} =
  ReqClient.start_task(
    subagent,
    %{assistant_id: subagent.graph_id, input: %{messages: [%{role: "user", content: "Research OTP."}]}},
    request_fun: request_fun
  )

{:ok, checked} =
  ReqClient.check_task(
    subagent,
    "thread/with spaces",
    request_fun: request_fun
  )

{:ok, updated} =
  ReqClient.update_task(
    subagent,
    "thread/with spaces",
    "Narrow the research to supervision trees.",
    request_fun: request_fun
  )

IO.inspect(started, label: "normalized start body")
IO.inspect(checked, label: "normalized check body")
IO.inspect(updated, label: "normalized update body")
