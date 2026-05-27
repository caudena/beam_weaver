alias BeamWeaver.Tracing.Exporters.LangSmith
alias BeamWeaver.Tracing.Run

run =
  Run.new("example",
    id: "run-example",
    trace_id: "trace-example",
    kind: :graph,
    metadata: %{model_provider: :fake, model_name: "chat"}
  )
  |> Map.put(:ended_at, DateTime.utc_now())
  |> Map.put(:status, :ok)

payload = LangSmith.to_payload(:ok, run, "beamweaver-example")
IO.puts(payload.extra.model_name)
