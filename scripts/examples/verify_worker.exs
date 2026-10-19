[request_path, evidence_path] = System.argv()
Code.require_file("evidence.exs", __DIR__)
job = request_path |> File.read!() |> :erlang.binary_to_term()
System.argv(job.args)
config = Application.get_env(:beam_weaver, :examples, [])
Application.put_env(:beam_weaver, :examples, Keyword.put(config, :model, job.model))
collector = BeamWeaver.Examples.Evidence.start()

failure =
  try do
    Code.eval_file(job.script)
    nil
  catch
    kind, reason -> {kind, reason, __STACKTRACE__}
  end

evidence = BeamWeaver.Examples.Evidence.finish(collector, job.required_providers)
File.write!(evidence_path, JSON.encode!(evidence))

case failure do
  {kind, reason, stack} -> :erlang.raise(kind, reason, stack)
  nil -> :ok
end

if evidence.missing_providers != [],
  do: raise("No successful live inference observed for #{inspect(evidence.missing_providers)}")

if evidence.unexpected_providers != [],
  do: raise("The example used an unexpected provider: #{inspect(evidence.unexpected_providers)}")

IO.puts("Verified #{evidence.successful_inference_requests} real provider inference responses.")
