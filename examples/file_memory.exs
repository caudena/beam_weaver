# Agent memory in a plain file on disk.
#
# `memory: ["/AGENTS.md"]` loads the file into the system prompt of every
# conversation, and the agent edits it with the ordinary file tools.
# `BeamWeaver.Filesystem.Local` maps the agent's paths onto a real directory,
# so the memory is a Markdown file you can open, edit, and keep in version
# control.
#
#   mix run examples/file_memory.exs
#   mix run examples/file_memory.exs --reset     # start over with an empty memory
#
# Run it twice: the second run starts with what the first one wrote.
# For memory kept as records in a store, see `examples/long_term_memory.exs`.

Code.require_file("support.exs", __DIR__)

alias BeamWeaver.Agent
alias BeamWeaver.Core.Message
alias BeamWeaver.Examples.Support
alias BeamWeaver.Filesystem.Local

root = Path.join(System.tmp_dir!(), "beam_weaver_file_memory")
memory_file = Path.join(root, "AGENTS.md")

if "--reset" in System.argv(), do: File.rm_rf!(root)

File.mkdir_p!(root)
unless File.exists?(memory_file), do: File.write!(memory_file, "# About the user\n\n- Name: Ada.\n")

IO.puts("Memory file: #{memory_file}\n\n#{File.read!(memory_file)}")

{:ok, agent} =
  Agent.build(
    name: "file_memory",
    model: Support.model(),
    model_opts: [timeout: 120_000],
    filesystem: Local.new(root: root),
    memory: ["/AGENTS.md"],
    system_prompt: """
    You are a personal assistant. When the user asks you to remember something, add one short line to /AGENTS.md \
    with edit_file and confirm in one sentence. Keep every answer to one or two sentences.
    """
  )

converse = fn text ->
  {:ok, %{messages: messages}} = Agent.invoke(agent, %{messages: [Message.user(text)]}, run_timeout: 240_000)

  tools = for %Message{role: :assistant, tool_calls: calls} <- messages, call <- calls, do: call.name

  IO.puts("[user] #{text}")
  if tools != [], do: IO.puts("  tools: #{Enum.join(tools, ", ")}")
  IO.puts("  agent: #{messages |> List.last() |> Message.text()}\n")
end

# Two separate conversations: the second one knows the preference only through the file.
converse.("Please remember that I prefer answers in German.")
converse.("How is the weather usually in Lisbon in May?")

IO.puts("Memory file after this run:\n\n#{File.read!(memory_file)}")
