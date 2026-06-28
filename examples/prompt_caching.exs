Code.require_file("support.exs", __DIR__)

alias BeamWeaver.Core.ChatModel
alias BeamWeaver.Core.Message
alias BeamWeaver.Examples.Support

model = Support.model()

system_prompt = """
You are a support analysis agent.

Use the support policy below when answering. The policy is intentionally long
and stable so repeated calls can reuse provider prompt caches.

#{String.duplicate("- Verify account ownership, preserve audit trails, cite the support rule id, and never invent data.\n", 240)}
"""

messages =
  Support.prompt_cache_messages(model, system_prompt, [
    Message.user("Ticket SUP-42 asks whether deleted exports can be restored.")
  ])

cache_opts = Support.prompt_cache_opts(model, "support-agent", system_prompt)

{:ok, first} = ChatModel.invoke(model, messages, cache_opts)
{:ok, second} = ChatModel.invoke(model, messages, cache_opts)

IO.puts(Message.text(second))
IO.puts("")
IO.puts("First cached input tokens: #{Support.cache_read_tokens(first)}")
IO.puts("Second cached input tokens: #{Support.cache_read_tokens(second)}")
