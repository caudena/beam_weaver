Code.require_file("support.exs", __DIR__)

alias BeamWeaver.Agent
alias BeamWeaver.Core.Message
alias BeamWeaver.Examples.Support

system_prompt = """
You are a support analysis agent.

Use the support policy below when answering. The policy is intentionally long
and stable so repeated calls can reuse provider prompt caches.

#{String.duplicate("- Verify account ownership, preserve audit trails, cite the support rule id, and never invent data.\n", 240)}
"""

{:ok, agent} =
  Agent.build(
    name: "prompt_caching_example",
    model: Support.model(),
    system_prompt: system_prompt,
    prompt_caching: [scope: "support-agent", version: "v1"]
  )

input = %{
  messages: [
    Message.user("Ticket SUP-42 asks whether deleted exports can be restored. Answer in one sentence.")
  ]
}

{:ok, first} = Agent.invoke(agent, input)
{:ok, second} = Agent.invoke(agent, input)

first_message = List.last(first.messages)
second_message = List.last(second.messages)

IO.puts(Message.text(second_message))
IO.puts("")
IO.puts("First cached input tokens: #{Support.cache_read_tokens(first_message)}")
IO.puts("Second cached input tokens: #{Support.cache_read_tokens(second_message)}")
