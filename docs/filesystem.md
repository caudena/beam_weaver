# Filesystem

Give an agent a filesystem and it gets tools to list, read, write, edit and
search files, which it uses for notes, drafts, skills, memory files and large
tool results. The files can live in the agent's state, in a directory, in a
memory store or in a sandbox, and one agent can mix them by path.

```elixir
defmodule MyApp.SupportResearcher do
  use BeamWeaver.Agent

  alias BeamWeaver.Models.FakeChatModel

  model "fake:chat",
    responses: [
      FakeChatModel.tool_call("grep", %{"pattern" => "Damaged", "path" => "/policies"}),
      FakeChatModel.tool_call("read_file", %{"file_path" => "/policies/refunds.md"}),
      FakeChatModel.tool_call("write_file", %{
        "file_path" => "/notes/A-1001.md",
        "content" => "Mug arrived broken. Damaged items get a full refund.\n"
      }),
      "Your mug arrived broken, so you get a full refund."
    ]

  system_prompt "You are Acme's support researcher. Check the policies in /policies before you answer."
  filesystem BeamWeaver.Filesystem.State.new()
end

policies = %{
  "/policies/refunds.md" =>
    "# Refunds\n\nDamaged items: full refund, no return needed.\nUnwanted items: refund within 30 days.\n",
  "/policies/shipping.md" => "# Shipping\n\nOrders ship within two business days.\n"
}

{:ok, result} =
  MyApp.SupportResearcher.invoke(%{messages: ["My mug arrived broken. What can you do?"], files: policies})

result.files["/notes/A-1001.md"].content
#=> "Mug arrived broken. Damaged items get a full refund.\n"
```

`BeamWeaver.Filesystem.State` keeps the files in the thread's state under
`files`. The input seeded two policies; the model searched them, read one and
wrote a note, and the result carries every file. Files you passed in come back
as you passed them, and files the agent wrote come back as
`BeamWeaver.Filesystem.FileData` structs with the text in `content`.
[Skills](skills.md) and [memory files](memory_files.md) are files in this
filesystem too.

## The file tools

| Tool | Arguments | What it does |
| --- | --- | --- |
| `ls` | `path` | Lists the files and folders directly under `path`. |
| `read_file` | `file_path`, `offset`, `limit` | Returns a file's text as it is: `limit` lines (default 2,000) after skipping `offset` lines (default 0), and at most 80,000 characters, cut at a whole line. A read that stops short of the end of the file ends with a note, such as `[Showing lines 1-2000. The file continues: read again with offset 2000.]`. An `offset` past the last line is an error that gives the file's length. An image (PNG, JPEG, GIF, WebP) or a PDF comes back as a content block after a short notice; any other binary file as a short notice. |
| `write_file` | `file_path`, `content` | Creates a file, or replaces an existing one. To change part of a file, use `edit_file`. |
| `edit_file` | `file_path`, `old_string`, `new_string`, `replace_all` | Replaces exact text. It fails when `old_string` is empty or isn't found, or is found more than once without `replace_all: true`. |
| `glob` | `pattern`, `path` | Lists the files under `path` that match a [glob pattern](#glob-patterns), such as `*.md`. |
| `grep` | `pattern`, `path`, `glob` | Finds lines that contain `pattern`, literal, case-sensitive text rather than a regex, in text files, and only in the files that match `glob` when you give one. A `path` that is a file searches that file. Binary files are left out, and in a directory or a sandbox so are `.git` folders below `path`. A search that finds nothing with a pattern that looks like a regex, such as `refund.*days`, ends with a note that grep matches literal text. |
| `execute` | `command`, `timeout` | Runs a shell command and returns its output and exit code, which your code also finds in the tool message's `metadata.exit_code` ([Sandboxes](sandboxes.md#exit-codes)). Only backends that can run commands add it. |

Paths are absolute and start with `/`, whatever the backend. A call that fails
returns a short error, such as `Error: string not found` from `edit_file`, so
the model can try again; `ls`, `glob` and `grep` of a `path` that doesn't
exist return `Error: file_not_found` rather than an empty list. The calls of one model reply run at the same time,
so a second `write_file` or `edit_file` on a path that an earlier call of the
reply changes is refused with an error, and the model changes the file again
in a later turn. `ls`, `glob` and `grep` return JSON:

```elixir
alias BeamWeaver.Core.Message

[grep_result | _rest] = for %{role: :tool} = message <- result.messages, do: Message.text(message)

JSON.decode!(grep_result)
#=> [%{"path" => "/policies/refunds.md", "line" => 3, "text" => "Damaged items: full refund, no return needed."}]
```

A listing or search over many files stops at 80,000 characters (about 20,000
tokens), after the last whole entry that fits. A note after the JSON says how
many of the results it shows and asks the model to narrow the search with a
more specific path or pattern.

The filesystem also adds a section to the system prompt that explains the
tools the model is offered; a tool taken away with `exclude_tools` isn't
mentioned. `grep`'s description works the same way: it says the pattern is
literal text and that the model runs one search for each of several strings,
and only while the model is offered `execute` does it add that a real regex
needs `execute` with `rg`. A description you set with `tool_descriptions`
stays as you wrote it. Tool results over about 20,000 tokens are saved to
`/large_tool_results/` and the model reads them a page at a time; see
[Context Management](context_management.md#move-large-tool-results-into-files).

### Glob patterns

`glob` and the `glob` of `grep` read a pattern the same way on every backend.
A pattern without `/` matches a file's name at any depth below `path`. A
pattern with `/` matches the file's path from `path`, where `**/` stands for
any number of folders, and a leading `/` keeps it to `path` itself, so `/*.md`
matches only the files directly in it. `*` and `?` match within one name,
`[abc]` and `[a-z]` match one character of the class and `[!a]` or `[^a]` one
that isn't in it, `{md,txt}` matches either, and `\` makes the next character
literal, so `lit\[1\].md` matches the file `lit[1].md`. A pattern with an
unclosed `[` or `{` returns the error `invalid_pattern`:

```elixir
files = Map.put(policies, "/policies/archive/2019.md", "# Old refunds\n")

for pattern <- ["*.md", "/*.md", "archive/*.md", "**/2019.md"] do
  %{matches: matches} =
    BeamWeaver.Filesystem.glob(BeamWeaver.Filesystem.State.new(), pattern, path: "/policies", state: %{files: files})

  {pattern, Enum.map(matches, & &1.path)}
end
#=> [
#     {"*.md", ["/policies/archive/2019.md", "/policies/refunds.md", "/policies/shipping.md"]},
#     {"/*.md", ["/policies/refunds.md", "/policies/shipping.md"]},
#     {"archive/*.md", ["/policies/archive/2019.md"]},
#     {"**/2019.md", ["/policies/archive/2019.md"]}
#   ]
```

A `Composite` reads a pattern with `/` from the path searched too: from `/`,
`policies/*.md` matches the files directly under a `/policies/` route.
[Permission rules](#permissions) have wildcards of their own: `*`, `?`, `**`
and `{a,b}`, without classes.

## Where the files live

| Backend | The files live | Shared by threads | `execute` |
| --- | --- | --- | --- |
| `BeamWeaver.Filesystem.State` | in the thread's state, saved with its checkpoints | no | no |
| `BeamWeaver.Filesystem.Local` | in a directory | yes | no |
| `BeamWeaver.Filesystem.LocalShell` | in a directory | yes | yes, on your machine |
| `BeamWeaver.Filesystem.Store` | in a memory store, under a namespace | yes | no |
| `BeamWeaver.Filesystem.Composite` | in other backends, chosen by path prefix | per route | when its default backend runs commands |
| `BeamWeaver.Filesystem.Sandbox` | in a sandbox | yes | yes, in the sandbox |

`State` is the default. `skills`, `memory`, `compact_conversation` and
`overflow_recovery` use it when the agent declares no filesystem, and
`Composite` sends paths to it unless a route matches. Its files belong to one
thread: pass them in with `files:`, read them from the result or with
`get_state/1`, and a checkpointer keeps them for the next call on the thread.
`BeamWeaver.Filesystem.upload_files/3` can't change them and returns an error
for each file.

### A directory

`BeamWeaver.Filesystem.Local` reads and writes a real directory. The agent
sees it as `/`:

```elixir
defmodule MyApp.SupportResearcher do
  use BeamWeaver.Agent

  alias BeamWeaver.Models.FakeChatModel

  model "fake:chat",
    responses: [
      FakeChatModel.tool_call("write_file", %{"file_path" => "/notes/A-1001.md", "content" => "Full refund.\n"}),
      "I saved a note for the refunds team."
    ]

  filesystem BeamWeaver.Filesystem.Local.new(root: Path.join(System.tmp_dir!(), "acme_support_files"))
end

root = Path.join(System.tmp_dir!(), "acme_support_files")
File.rm_rf!(root)

{:ok, _result} = MyApp.SupportResearcher.invoke(%{messages: ["Note that A-1001 gets a full refund."]})
File.read!(Path.join(root, "notes/A-1001.md"))
#=> "Full refund.\n"
```

`Local.new/1` creates the directory if needed. Paths and the patterns of
`glob` and `grep` can't leave it: `..`, `~` and symlinks that point outside
are rejected, and `ls`, `glob` and `grep` leave such symlinks out. The agent
can change any file in the directory, so give it a directory of its own, or
limit it with [permissions](#permissions).

### Run commands

`BeamWeaver.Filesystem.LocalShell` is a `Local` directory that can also run
commands. An agent with it gets the `execute` tool, which runs a command with
`sh` in the directory and returns what it printed and its exit code. Your code
can run one the same way:

```elixir
shell = BeamWeaver.Filesystem.LocalShell.new(root: root, timeout: 30)
BeamWeaver.Filesystem.Executable.execute(shell, "ls notes").output
#=> "A-1001.md\n"
```

`timeout:` is in seconds (default 120); a command that runs longer is stopped.
Commands don't inherit your application's environment variables, such as API
keys: they get `PATH`, `HOME`, `LANG`, the `LC_*` variables, `TMPDIR`, `USER`
and `SHELL`, plus the variables in `env:`. `inherit_env: true` passes the whole
environment instead. Output longer than `max_output_bytes:` (default 100,000)
keeps its first and last 50,000 bytes, with a line between them that says how
many bytes were cut, such as `... [48210 bytes cut] ...`.

{% hint style="danger" %}
`LocalShell` is not a sandbox. Commands run on your machine as the user that
runs your application, and file permissions don't apply to them. Use it for
development and trusted tasks only; run anything else in a
[sandbox](sandboxes.md).
{% endhint %}

### A memory store

`BeamWeaver.Filesystem.Store` keeps files as records of a memory store, under
a namespace. Every thread that uses the namespace sees the same files. Create
the store once and pass it with `store:` on each call, as for
[long-term memory](long_term_memory.md):

```elixir
store = BeamWeaver.Memory.ETS.new()

defmodule MyApp.SupportResearcher do
  use BeamWeaver.Agent

  alias BeamWeaver.Models.FakeChatModel

  model "fake:chat",
    responses: [
      FakeChatModel.tool_call("write_file", %{"file_path" => "/A-1001.md", "content" => "Full refund approved.\n"}),
      "I saved a note for the refunds team."
    ]

  filesystem BeamWeaver.Filesystem.Store.new(namespace: ["acme", "case_notes"])
end

{:ok, _result} = MyApp.SupportResearcher.invoke(%{messages: ["Note that A-1001 gets a full refund."]}, store: store)

case_notes = BeamWeaver.Filesystem.Store.new(store: store, namespace: ["acme", "case_notes"])
[file] = BeamWeaver.Filesystem.download_files(case_notes, ["/A-1001.md"])
file.content
#=> "Full refund approved.\n"
```

Your application reads and writes the same files with
`BeamWeaver.Filesystem.download_files/3` and
`BeamWeaver.Filesystem.upload_files/3`, which replaces existing files.
`namespace:` can also be a function of the run's runtime, to give each
customer their own files; see
[Memory Files](memory_files.md#one-set-of-files-per-customer). Each file is
one record of plain data, so any memory store works, `Memory.Ecto` included,
and a store that fails to save a file returns the error to the tool, which
the model sees as `Error: ...`.

### Mix backends by path

`BeamWeaver.Filesystem.Composite` sends each path to a backend by its prefix.
Here the team's policies come from the store, shared and maintained by your
application, while the agent's own notes stay in the thread:

```elixir
policies_dir = BeamWeaver.Filesystem.Store.new(store: store, namespace: ["acme", "policies"])
[%{error: nil}] = BeamWeaver.Filesystem.upload_files(policies_dir, [{"/refunds.md", policies["/policies/refunds.md"]}])

defmodule MyApp.SupportResearcher do
  use BeamWeaver.Agent

  alias BeamWeaver.Filesystem
  alias BeamWeaver.Models.FakeChatModel

  model "fake:chat",
    responses: [
      FakeChatModel.tool_call("read_file", %{"file_path" => "/policies/refunds.md"}),
      FakeChatModel.tool_call("write_file", %{"file_path" => "/notes/A-1001.md", "content" => "Full refund.\n"}),
      "Damaged items get a full refund."
    ]

  filesystem Filesystem.Composite.new(
               default: Filesystem.State.new(),
               routes: %{"/policies/" => Filesystem.Store.new(namespace: ["acme", "policies"])}
             )
end

{:ok, result} = MyApp.SupportResearcher.invoke(%{messages: ["My mug arrived broken."]}, store: store)
Map.keys(result.files)
#=> ["/notes/A-1001.md"]
```

The longest matching prefix wins, and paths that match no route go to
`default` (`State` unless you set it). The model sees one tree: `ls /` lists
`/policies` next to the default backend's files, and `glob` and `grep` from
`/` search every backend and return full paths. A route can sit deeper, such
as `/workspace/memories/`: `ls /` then shows `/workspace`, `ls /workspace`
shows `/workspace/memories` next to the default backend's files there, and
a search of `/workspace` searches the route too, even when the default
backend has nothing else under `/workspace`. If a backend fails, the call
returns that backend's error instead of partial results. A `State` route keeps its
files in the thread's `files` under their full paths and sees only the files
under its prefix:

```elixir
scratch = BeamWeaver.Filesystem.Composite.new(routes: %{"/scratch/" => BeamWeaver.Filesystem.State.new()})
%{files_update: files} = BeamWeaver.Filesystem.write(scratch, "/scratch/draft.md", "Draft reply", state: %{})
Map.keys(files)
#=> ["/scratch/draft.md"]
```

### A sandbox

`BeamWeaver.Filesystem.Sandbox` turns a sandbox into a filesystem with
`execute`, so commands run where the files are. `BeamWeaver.Sandbox.local/1`
keeps the files in a local directory and runs commands on your machine, for
development. [Sandboxes](sandboxes.md) covers Docker and hosted sandboxes,
which isolate the commands:

```elixir
model "anthropic:claude-sonnet-4-6"
filesystem BeamWeaver.Filesystem.Sandbox.new(sandbox: BeamWeaver.Sandbox.local(root: "/tmp/acme_workspace"))
```

## Permissions

`filesystem_permissions` sets which paths the file tools may read and write.
Each rule is a `BeamWeaver.Filesystem.Permission`:

| Field | Default | Meaning |
| --- | --- | --- |
| `operations` | `[:read, :write]` | `:read` covers `ls`, `read_file`, `glob` and `grep`; `:write` covers `write_file` and `edit_file` |
| `paths` | `["/**"]` | absolute path patterns: `/policies/**` is the folder and everything in it, `/**/secrets/**` every `secrets` folder; `*`, `?` and `{refunds,shipping}.md` work too |
| `mode` | `:allow` | `:allow` or `:deny` |

Rules are checked in order, and the first rule that matches decides. When no
rule matches, the call is allowed. So put narrow rules before broad ones:

```elixir
alias BeamWeaver.Filesystem.Permission

rules = [
  Permission.new(paths: ["/workspace/.env", "/workspace/secrets/**"], mode: :deny),
  Permission.new(paths: ["/workspace/**"], mode: :allow),
  Permission.new(paths: ["/**"], mode: :deny)
]

for path <- ["/workspace/notes.md", "/workspace/secrets/api_key.txt", "/etc/hosts"],
    do: Permission.allowed?(rules, :read, path)
#=> [true, false, false]
```

Rules see a path as the backends read it, so `/workspace/./.env` is
`/workspace/.env`. With rules in place, a path that the backends could read
another way, such as one with `..`, is denied. Deny rules also ignore case,
because a disk that ignores it, such as macOS's, opens `/workspace/.env` for
`/WORKSPACE/.ENV`; allow rules match case exactly:

```elixir
for path <- ["/workspace/./.env", "/WORKSPACE/.ENV", "/workspace/../etc/hosts", "/Workspace/notes.md"],
    do: Permission.allowed?(rules, :read, path)
#=> [false, false, false, false]
```

Rules also see through symlinks. On a backend with links (`Local`,
`LocalShell` and sandboxes), the file tools check a path as the model wrote
it and as the file it leads to, and both must be allowed. A link to a denied
file, or into a denied folder, is denied like the file itself, and `ls`,
`glob` and `grep` leave it out:

```elixir
links = Path.join(System.tmp_dir!(), "acme_permission_links")
File.rm_rf!(links)
File.mkdir_p!(Path.join(links, "workspace/secrets"))
File.mkdir_p!(Path.join(links, "workspace/notes"))
File.write!(Path.join(links, "workspace/secrets/api_key.txt"), "sk-test")
File.ln_s!("../secrets/api_key.txt", Path.join(links, "workspace/notes/key.txt"))
files = BeamWeaver.Filesystem.Local.new(root: links)

{Permission.allowed?(rules, :read, "/workspace/notes/key.txt"),
 Permission.allowed?(rules, :read, "/workspace/notes/key.txt", files),
 BeamWeaver.Filesystem.canonical_paths(files, ["/workspace/notes/key.txt"])}
#=> {true, false, [ok: "/workspace/secrets/api_key.txt"]}
```

The path alone is allowed, but it leads to `/workspace/secrets/api_key.txt`,
which a rule denies. A new file is checked as the file it would become, so
`write_file` can't create one through a link into a denied folder, while new
files in allowed folders work as before. With rules in place, a path the
backend can't resolve, such as a broken link, is denied.

Two gaps remain. A hard link is a second name for the same file that no rule
can tell apart, so don't hard-link a denied file where the agent can read.
And the tools resolve links just before each call, so a process that changes
a link in between can send the call to another file: don't let untrusted
processes change links in the agent's directory while it works.

Give the rules to the agent with `filesystem_permissions`. This agent may read
the policies but not change them:

```elixir
defmodule MyApp.SupportResearcher do
  use BeamWeaver.Agent

  alias BeamWeaver.Filesystem.Permission
  alias BeamWeaver.Models.FakeChatModel

  model "fake:chat",
    responses: [
      FakeChatModel.tool_call("edit_file", %{
        "file_path" => "/policies/refunds.md",
        "old_string" => "30 days",
        "new_string" => "90 days"
      }),
      "I can't change our policies, but a manager can approve an exception."
    ]

  filesystem BeamWeaver.Filesystem.State.new()
  filesystem_permissions [Permission.new(operations: [:write], paths: ["/policies/**"], mode: :deny)]
end

{:ok, result} = MyApp.SupportResearcher.invoke(%{messages: ["Give me 90 days to return my mug."], files: policies})
result.messages |> Enum.find(&(&1.role == :tool)) |> Message.text()
#=> "Error: Permission denied editing /policies/refunds.md"
```

A denied path also disappears from the results of `ls`, `glob` and `grep`.
`glob` and `grep` check their `path`, which is `/` when the model leaves it
out, so with the `rules` above a `glob` of `/workspace/**/*.md` without a
`path` is denied, although `/workspace` is allowed. When the model left
`path` out, the error tells it to retry with a `path` inside an allowed
directory, and for `glob` with a `pattern` relative to it.

The tools stay in the model's tool list; to take a tool away, use
`exclude_tools ["write_file", "edit_file"]`. Permissions cover only the six
file tools: not `execute`, not your own tools, and not your application's
calls to `BeamWeaver.Filesystem` functions.

### Subagent permissions

A subagent module that declares a `filesystem` has its own file tools. To
give a subagent the parent's files instead, ask for file tools on its
`subagent` line with `base_middleware:`: it then works on the parent's
filesystem with the parent's rules, unless you give it its own
`permissions:`. This policy expert may read the policies but not write
anywhere:

```elixir
defmodule MyApp.PolicyExpert do
  use BeamWeaver.Agent

  alias BeamWeaver.Models.FakeChatModel

  @script [
    FakeChatModel.tool_calls([
      {"read_file", %{"file_path" => "/policies/refunds.md"}},
      {"edit_file", %{"file_path" => "/policies/refunds.md", "old_string" => "30 days", "new_string" => "90 days"}}
    ]),
    "Unwanted items can be refunded within 30 days."
  ]

  name "policy_expert"
  description "Answers questions about Acme's policies from the files in /policies."
  model "fake:chat", responses: @script
end

defmodule MyApp.SupportResearcher do
  use BeamWeaver.Agent

  alias BeamWeaver.Agent.Middleware
  alias BeamWeaver.Filesystem.Permission
  alias BeamWeaver.Models.FakeChatModel

  model "fake:chat",
    responses: [
      FakeChatModel.tool_call("task", %{
        "subagent_type" => "policy_expert",
        "description" => "How long can customers return unwanted items?"
      }),
      "You can return it within 30 days."
    ]

  filesystem BeamWeaver.Filesystem.State.new()

  subagents do
    subagent MyApp.PolicyExpert,
      base_middleware: [Middleware.Filesystem],
      permissions: [Permission.new(operations: [:write], mode: :deny)]
  end
end

{:ok, result} = MyApp.SupportResearcher.invoke(%{messages: ["How long do I have to return a mug?"], files: policies})
result.files["/policies/refunds.md"] == policies["/policies/refunds.md"]
#=> true
```

The subagent's edit was denied, so the policy is unchanged. Without
`permissions:`, its edit would have reached the parent's files. Pass
`permissions: []` for full access. The built-in `general-purpose` subagent
always has file tools and the parent's rules. See [Subagents](subagents.md).

### Composite and executable backends

Rules match the paths the model uses, route prefixes included, so a rule on
`/policies/**` covers a `Composite` route mounted at `/policies/`. The file a
path leads to is found by the route's backend and keeps the route's prefix.

`execute` is outside the rules: a command can read or change any file the
backend's machine allows. A `Composite` offers `execute` when its default
backend can run commands, so keep a non-executable default when routes hold
data the agent must not change. Pause before commands with
`interrupt_on %{"execute" => true}` ([Human-in-the-Loop](human_in_the_loop.md)),
and isolate them in a [sandbox](sandboxes.md).

## Wrap a backend for policy checks

For checks that path rules can't express, such as what a file contains, wrap
the backend in a module of your own. `use BeamWeaver.Filesystem` declares the
callbacks; check what you need and pass the rest to the inner backend. This
one refuses notes that contain a card number:

```elixir
defmodule MyApp.NoCardNumbers do
  use BeamWeaver.Filesystem

  alias BeamWeaver.Filesystem

  defstruct [:inner]

  @refusal "notes must not contain card numbers"

  @impl true
  def write(fs, path, content, opts) do
    if card_number?(content),
      do: %Filesystem.WriteResult{path: path, error: @refusal},
      else: Filesystem.write(fs.inner, path, content, opts)
  end

  @impl true
  def edit(fs, path, old, new, opts) do
    if card_number?(new),
      do: %Filesystem.EditResult{path: path, error: @refusal},
      else: Filesystem.edit(fs.inner, path, old, new, opts)
  end

  @impl true
  def ls(fs, path, opts), do: Filesystem.ls(fs.inner, path, opts)
  @impl true
  def read(fs, path, opts), do: Filesystem.read(fs.inner, path, opts)
  @impl true
  def glob(fs, pattern, opts), do: Filesystem.glob(fs.inner, pattern, opts)
  @impl true
  def grep(fs, pattern, opts), do: Filesystem.grep(fs.inner, pattern, opts)
  @impl true
  def upload_files(fs, files, opts), do: Filesystem.upload_files(fs.inner, files, opts)
  @impl true
  def download_files(fs, paths, opts), do: Filesystem.download_files(fs.inner, paths, opts)
  @impl true
  def canonical_paths(fs, paths, opts), do: Filesystem.canonical_paths(fs.inner, paths, opts)

  defp card_number?(content), do: IO.iodata_to_binary(content) =~ ~r/\b(?:\d[ -]?){13,16}\b/
end
```

`canonical_paths/3` is optional, but a wrapper should pass it on: it tells
[permissions](#permissions) where the inner backend's symlinks lead, and a
backend without it is taken to have none.

Wrap any backend, here the thread's state, and try a write:

```elixir
fs = %MyApp.NoCardNumbers{inner: BeamWeaver.Filesystem.State.new()}
BeamWeaver.Filesystem.write(fs, "/notes/ada.md", "Card: 4111 1111 1111 1111").error
#=> "notes must not contain card numbers"
```

Give the wrapper to an agent like any backend, with
`filesystem %MyApp.NoCardNumbers{inner: BeamWeaver.Filesystem.State.new()}`,
and a refused write reaches the model as
`Error: notes must not contain card numbers`. A wrapper also works under a
`Composite` route and together with `filesystem_permissions`, and suits
logging, quotas and per-tenant checks. The file tools call `ls`, `read`,
`write`, `edit`, `glob` and `grep`, permissions call `canonical_paths`, and
skills load with `download_files`; only your application calls
`upload_files`.

## Change the large-result limits

The file tools come from `BeamWeaver.Agent.Middleware.Filesystem`. To change
its options, list it in `middleware` with them:

```elixir
model "anthropic:claude-sonnet-4-6"
filesystem BeamWeaver.Filesystem.State.new()

middleware [
  {BeamWeaver.Agent.Middleware.Filesystem,
   tool_token_limit_before_evict: 5_000,
   human_message_token_limit_before_evict: nil}
]
```

`tool_token_limit_before_evict` (default 20,000) and
`human_message_token_limit_before_evict` (default 50,000) set when a tool
result or a user message is moved into a file; `nil` turns that off. Your
entry replaces the one that `filesystem` adds, and keeps its backend and its
`filesystem_permissions` unless you give `backend:` or `permissions:` too.

## Write a backend

The wrapper above is a complete backend. One of your own, for object storage
or your own tables, implements the same callbacks:

| Callback | Returns |
| --- | --- |
| `ls/3` | `%BeamWeaver.Filesystem.LsResult{entries: [%FileInfo{}]}` |
| `read/3` | `%ReadResult{file_data: %FileData{}}`, honoring the `:offset` and `:limit` options |
| `write/4` | `%WriteResult{path: path}`, replacing a file that exists |
| `edit/5` | `%EditResult{path: path, occurrences: n}` |
| `glob/3`, `grep/3` | `%GlobResult{matches: [%FileInfo{}]}`, `%GrepResult{matches: [%GrepMatch{}]}`, matching patterns as in [Glob patterns](#glob-patterns) |
| `upload_files/3`, `download_files/3` | a list of `%UploadResult{}` or `%DownloadResult{}` |
| `canonical_paths/3` (optional) | `[{:ok, path}]`: for each path, the path of the file it reaches with symlinks followed. Leave it out when your storage has no links |

Return failures in the result's `error` field instead of raising; the tools
pass the error to the model. To give the agent `execute` too, add
`use BeamWeaver.Filesystem.Executable` and two more callbacks to the module.
These run each command in a Docker container that mounts the backend's
directory; `opts` carries the model's `timeout:` in seconds:

```elixir
use BeamWeaver.Filesystem.Executable

alias BeamWeaver.Filesystem.Executable.ExecuteResult

@impl true
def id(workspace), do: "container:" <> workspace.container

@impl true
def execute(workspace, command, _opts) do
  {output, exit_code} =
    System.cmd("docker", ["exec", workspace.container, "sh", "-c", command], stderr_to_stdout: true)

  %ExecuteResult{exit_code: exit_code, output: output}
end
```

### Check that permissions see your links

When your storage has symlinks, [permissions](#permissions) rely on your
`canonical_paths/3`: a link it doesn't resolve gives a denied file an allowed
name, and so does a wrapper that doesn't pass the call on.
`BeamWeaver.Filesystem.Conformance.check_symlinks/3` checks this from your
backend's tests. Give it a new, empty backend and a function that makes a
link in the backend's storage, called as `make_link.(link, target)` with both
paths as the backend sees them. It writes a secret to `/secrets/key.txt`,
links `/notes/key.txt` and `/notes/vault` to it, and, with a rule that denies
`/secrets/**`, checks that the file tools can't read, list, search, write or
edit the secret through the links, while the rest of `/notes` stays open. The
card-number wrapper above, over a directory, passes:

```elixir
root = Path.join(System.tmp_dir!(), "acme_link_check")
File.rm_rf!(root)
files = %MyApp.NoCardNumbers{inner: BeamWeaver.Filesystem.Local.new(root: root)}
make_link = fn link, target -> File.ln_s!(Path.join(root, target), Path.join(root, link)) end

BeamWeaver.Filesystem.Conformance.check_symlinks(files, make_link)
#=> :ok
```

Without its `canonical_paths/3` line, the wrapper fails: `check_symlinks/3`
returns `{:error, problems}` with a sentence for each leak, such as
`"read_file /notes/key.txt wasn't denied: it returned the text of a file a rule denies"`.
In a test, `assert check_symlinks(backend, make_link) == :ok` shows them all.
Pass `dir: "/ws"` to check under a folder, such as a `Composite` route. A
backend whose storage has no links needs no check.

## Reference

- [`BeamWeaver.Filesystem`](https://hexdocs.pm/beam_weaver/BeamWeaver.Filesystem.html): the backend behaviour, its result structs, and functions to read and write files
- [`BeamWeaver.Filesystem.State`](https://hexdocs.pm/beam_weaver/BeamWeaver.Filesystem.State.html): files in the thread's state
- [`BeamWeaver.Filesystem.Local`](https://hexdocs.pm/beam_weaver/BeamWeaver.Filesystem.Local.html): files in a directory
- [`BeamWeaver.Filesystem.LocalShell`](https://hexdocs.pm/beam_weaver/BeamWeaver.Filesystem.LocalShell.html): a directory plus `execute` on your machine
- [`BeamWeaver.Filesystem.Store`](https://hexdocs.pm/beam_weaver/BeamWeaver.Filesystem.Store.html): files in a memory store
- [`BeamWeaver.Filesystem.Composite`](https://hexdocs.pm/beam_weaver/BeamWeaver.Filesystem.Composite.html): backends mounted under path prefixes
- [`BeamWeaver.Filesystem.Sandbox`](https://hexdocs.pm/beam_weaver/BeamWeaver.Filesystem.Sandbox.html): a sandbox as a filesystem with `execute`
- [`BeamWeaver.Filesystem.Permission`](https://hexdocs.pm/beam_weaver/BeamWeaver.Filesystem.Permission.html): read and write rules for the file tools
- [`BeamWeaver.Filesystem.Executable`](https://hexdocs.pm/beam_weaver/BeamWeaver.Filesystem.Executable.html): the behaviour for backends that run commands
- [`BeamWeaver.Filesystem.Conformance`](https://hexdocs.pm/beam_weaver/BeamWeaver.Filesystem.Conformance.html): checks to run from a backend's tests
- [`BeamWeaver.Agent.Middleware.Filesystem`](https://hexdocs.pm/beam_weaver/BeamWeaver.Agent.Middleware.Filesystem.html): the middleware behind `filesystem`
- [`BeamWeaver.Tools.Filesystem`](https://hexdocs.pm/beam_weaver/BeamWeaver.Tools.Filesystem.html): the file tools
