Code.require_file("support/http_receiver.exs", __DIR__)
alias BeamWeaver.Tracing
alias BeamWeaver.Tracing.Exporters.WeaveScope

{endpoint, receiver} = BeamWeaver.Examples.HTTPReceiver.start()
{:ok, run} = Tracing.start_run("documentation-export", exporter: nil, inputs: %{question: "Hello"})
{:ok, run} = Tracing.finish_run(run, outputs: %{answer: "Ready"})
:ok = WeaveScope.export(:ok, run, endpoint: endpoint, api_key: "local-documentation-fixture")
request = Task.await(receiver, 10_000)
true = request.method == :POST
true = request.path == "/api/v1/observations/batch"
[event] = request.body["events"]
true = event["observation_id"] == run.id
true = event["name"] == "documentation-export"
IO.puts("Received and checked the exported observation over local HTTP.")
