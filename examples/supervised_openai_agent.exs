alias BeamWeaver.Core.ChatModel
alias BeamWeaver.Core.Message
alias BeamWeaver.Runtime.Agent
alias BeamWeaver.Tracing

Tracing.reset()

model =
  BeamWeaver.OpenAI.chat_model(
    api_key: "sk-replay",
    transport: BeamWeaver.Transport.Replay,
    transport_opts: [cassette_path: "priv/openai/cassettes/supervised_openai_agent.yaml"]
  )

{:ok, agent} = Agent.start_child(id: "supervised_openai_agent_example")
:ok = Agent.subscribe(agent)
{:ok, _run} = Tracing.start_run("supervised OpenAI replay example")

{:ok, work} =
  Agent.start_model_call(
    agent,
    [Message.user("agent ping")],
    fn messages -> ChatModel.invoke(model, messages) end,
    timeout: 1_000
  )

receive do
  {:beam_weaver_agent, _agent_id, {:completed, work_id, response}} when work_id == work.id ->
    IO.puts(Message.text(response))

  {:beam_weaver_agent, _agent_id, {:failed, work_id, error}} when work_id == work.id ->
    raise "model call failed: #{inspect(error)}"
after
  1_500 ->
    raise "model call timed out"
end
