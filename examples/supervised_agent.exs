Code.require_file("support.exs", __DIR__)

alias BeamWeaver.Core.ChatModel
alias BeamWeaver.Core.Message
alias BeamWeaver.Examples.Support
alias BeamWeaver.Runtime.Agent
alias BeamWeaver.Tracing

Tracing.reset()

model = Support.model()

{:ok, agent} = Agent.start_child(id: "supervised_agent_example")
:ok = Agent.subscribe(agent)
{:ok, _run} = Tracing.start_run("supervised agent example")

{:ok, work} =
  Agent.start_model_call(
    agent,
    [Message.user("Say hello in one short sentence.")],
    fn messages -> ChatModel.invoke(model, messages) end,
    timeout: 30_000
  )

receive do
  {:beam_weaver_agent, _agent_id, {:completed, work_id, response}} when work_id == work.id ->
    IO.puts(Message.text(response))

  {:beam_weaver_agent, _agent_id, {:failed, work_id, error}} when work_id == work.id ->
    raise "model call failed: #{inspect(error)}"
after
  35_000 ->
    raise "model call timed out"
end
