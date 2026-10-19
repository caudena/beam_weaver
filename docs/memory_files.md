# Memory Files

Memory files are short Markdown notes loaded into an agent's instructions
at the beginning of a run. Use them for a team's working conventions or
preferences people also read and edit. Use [structured memory](long_term_memory.md)
when your application needs searchable records and explicit CRUD operations.

Complete [Installation](installation.md), then run this example in IEx.


Run this page’s examples in order in one IEx session; later blocks reuse the modules and values defined earlier.

## Remember a preference in a file

```elixir
defmodule MyApp.FileMemoryAgent do
  use BeamWeaver.Agent

  model "openai:gpt-5.4-mini", max_tokens: 512, timeout: 60_000
  system_prompt "Use /AGENTS.md for preferences. When asked to remember a fact, edit that file before confirming."
  filesystem BeamWeaver.Filesystem.State.new()
  memory ["/AGENTS.md"]
  recursion_limit 20
end

saver = BeamWeaver.Checkpoint.ETS.new()
opts = [checkpointer: saver, config: %{"configurable" => %{"thread_id" => "preferences"}}]

{:ok, saved} =
  MyApp.FileMemoryAgent.invoke(
    %{
      messages: ["Remember that my preferred temperature unit is Celsius."],
      files: %{"/AGENTS.md" => "# Preferences\n\n- Reply briefly.\n"}
    },
    opts
  )

true = saved.files["/AGENTS.md"].content =~ "Celsius"

{:ok, recalled} = MyApp.FileMemoryAgent.invoke(%{messages: ["Which temperature unit do I prefer?"]}, opts)
true = recalled.messages |> List.last() |> BeamWeaver.Core.Message.text() |> String.contains?("Celsius")
```

The first call verifies the actual file change. The next run loads that
updated file. State-backed files live in the thread and are checkpointed;
this ETS-backed example lasts only as long as its owner process.

## What the model sees

`memory [paths]` adds each file's content under an `agent_memory` section,
followed by guidance to treat it as reference material. `memory true` uses
`/AGENTS.md`. Files are loaded once per run in the declared order.

An edit does not replace the already-loaded prompt during the current run.
The new version is loaded on the next run. Missing/empty files are skipped;
HTML comments are removed. Keep files short because the loaded contents
accompany model calls. Put longer procedures in [Skills](skills.md), which
are discovered and read as needed.

Memory can contain mistakes or untrusted text. It should not override fresh
user instructions, authorization rules or verified tool evidence.

## How the agent updates a memory file

With a filesystem capability, the agent uses ordinary `read_file`, `edit_file`
and `write_file` tools. Tell it which file owns which kind of fact. Exact-string
edits can fail when content changed concurrently; shared writable files need
an application policy for conflicting updates.

`memory` alone can read files from state but does not add editing tools.
Declare `filesystem` when the agent should change them. Restrict shared policy
files with [filesystem permissions](filesystem.md#permissions).

## Which filesystem holds the files

| Backend | Lifetime and sharing |
| --- | --- |
| `Filesystem.State` | Per-thread files; persistence follows the checkpointer |
| `Filesystem.Store` | Shared within a memory-store namespace; durability follows that store |
| `Filesystem.Local` | Files in a configured directory; durability follows the disk/volume |
| `Filesystem.Composite` | Different backends mounted at path prefixes |

A temporary local directory is not durable production storage. For shared
notes use a persistent volume or store, and isolate tenants by root or
namespace. [Filesystem](filesystem.md) explains backend behavior.

## Seed, read and edit memory files from your application

Use the same filesystem backend as the agent:

```elixir
alias BeamWeaver.Filesystem
store = BeamWeaver.Memory.ETS.new()
backend = Filesystem.Store.new(store: store, namespace: ["customers", "ada", "files"])
[%{error: nil}] = Filesystem.upload_files(backend, [{"/AGENTS.md", "- Prefer Celsius.\n"}])
[file] = Filesystem.download_files(backend, ["/AGENTS.md"])
"- Prefer Celsius.\n" = file.content
```

Upload replaces existing contents. State-backed files are seeded through the
agent input and read from its result or snapshot. Local files can also be
managed through Elixir's `File` API.

Edit a stored preference through the same filesystem interface:

```elixir
alias BeamWeaver.Filesystem

store = BeamWeaver.Memory.ETS.new()
ada_files = Filesystem.Store.new(store: store, namespace: ["customers", "ada", "files"])

[%{error: nil}] = Filesystem.upload_files(ada_files, [{"/AGENTS.md", "- Prefers email.\n"}])

%{error: nil} = Filesystem.edit(ada_files, "/AGENTS.md", "email", "phone")
[file] = Filesystem.download_files(ada_files, ["/AGENTS.md"])
"- Prefers phone.\n" = file.content
```

## One set of files per customer

`Filesystem.Store` accepts a `namespace:` function of the runtime. Build the
namespace from `runtime.context.customer_id`, validated by `context_schema`.
A composite filesystem can mount read-only team rules at `/team/` and
customer notes at `/customer/`.

Load both paths with `memory`, but deny writes to the team path through
filesystem permissions. Apply matching ownership checks to application-side
reads and maintenance jobs. See [Runtime Context](runtime_context.md) and
[Long-Term Memory](long_term_memory.md#scope-memory-per-customer).

Mount team policy separately from each caller’s notes. An update for Ada must leave Bob’s notes and the shared policy unchanged:

```elixir
alias BeamWeaver.Filesystem
team = Filesystem.Store.new(store: store, namespace: ["teams", "support", "files"])
bob = Filesystem.Store.new(store: store, namespace: ["customers", "bob", "files"])
[%{error: nil}] = Filesystem.upload_files(team, [{"/AGENTS.md", "- Refunds over $500 need manager review.\n"}])
[%{error: nil}] = Filesystem.upload_files(bob, [{"/AGENTS.md", "- Prefers email.\n"}])

defmodule MyApp.CustomerNotesAgent do
  use BeamWeaver.Agent
  alias BeamWeaver.Filesystem
  model "openai:gpt-5.4-mini", max_tokens: 512, timeout: 60_000
  system_prompt "Update customer preferences only in /customer/AGENTS.md using the file tools."

  filesystem Filesystem.Composite.new(
               routes: %{
                 "/team/" => Filesystem.Store.new(namespace: ["teams", "support", "files"]),
                 "/customer/" =>
                   Filesystem.Store.new(
                     namespace: fn runtime -> ["customers", runtime.context.customer_id, "files"] end
                   )
               }
             )

  filesystem_permissions [Filesystem.Permission.new(operations: [:write], paths: ["/team/**"], mode: :deny)]
  memory ["/team/AGENTS.md", "/customer/AGENTS.md"]

  context_schema do
    field :customer_id, :string, required: true
  end
end

{:ok, _} =
  MyApp.CustomerNotesAgent.invoke(%{messages: ["Update my stored contact preference from phone to sms."]},
    store: store,
    context: %{customer_id: "ada"}
  )

[ada_note] = Filesystem.download_files(ada_files, ["/AGENTS.md"])
true = String.downcase(ada_note.content) =~ "sms"
[%{content: "- Prefers email.\n"}] = Filesystem.download_files(bob, ["/AGENTS.md"])
[%{content: "- Refunds over $500 need manager review.\n"}] = Filesystem.download_files(team, ["/AGENTS.md"])
```
