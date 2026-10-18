# Filesystem

A filesystem gives an agent tools to read, search, create and edit files.
Choose the backend based on who owns the data and how long it must live.
Filesystem paths are virtual absolute paths starting with `/`; a local root
maps them into a specific directory.

Complete [Installation](installation.md). This real OpenAI example reads
supplied source material and writes an observable result in thread state.

## Read a source and create a note

```elixir
defmodule MyApp.WorkspaceAgent do
  use BeamWeaver.Agent

  model "openai:gpt-5.4-mini", max_tokens: 512, timeout: 60_000
  system_prompt "Read the source file before writing a note. Preserve the exact order ID and delivery day."
  filesystem BeamWeaver.Filesystem.State.new()
  recursion_limit 20
end

{:ok, result} =
  MyApp.WorkspaceAgent.invoke(%{
    messages: ["Read /orders/A-1001.md and save its facts in /notes/A-1001.md."],
    files: %{"/orders/A-1001.md" => "Order A-1001 arrives Thursday.\n"}
  })

true = Enum.any?(result.messages, &(&1.role == :tool and &1.name == "read_file"))
note = result.files["/notes/A-1001.md"].content
true = note =~ "A-1001"
true = note =~ "Thursday"
```

Input strings seed state files. Agent-written files are `Filesystem.FileData`
values with `content`. A checkpointer keeps state files between calls on the
same thread. Without it, carry the files forward explicitly or use another
backend.

## Where the files live

| Backend | Storage | Command execution |
| --- | --- | --- |
| `State` | Thread state; durability follows checkpoints | No |
| `Local` | A directory shared by callers using that root | No |
| `LocalShell` | Local directory | On the application host |
| `Store` | Memory-store records under a namespace | No |
| `Composite` | Routes by virtual path prefix | Through its default backend only |
| `Sandbox` | A sandbox's filesystem | Inside that sandbox |

Modules are under `BeamWeaver.Filesystem`. Creating a backend value does not
make its underlying storage durable. Store-backed files work with the memory
adapter's persistence, including Ecto; state files remain thread-local.

### A directory

Application code can use the same backend. This creates and removes a unique
temporary directory:

```elixir
alias BeamWeaver.Filesystem
root = Path.join(System.tmp_dir!(), "beam-weaver-files-#{System.unique_integer([:positive])}")

try do
  backend = Filesystem.Local.new(root: root)
  [%{error: nil}] = Filesystem.upload_files(backend, [{"/notes/demo.md", "A-1001 arrives Thursday.\n"}])
  [download] = Filesystem.download_files(backend, ["/notes/demo.md"])
  "A-1001 arrives Thursday.\n" = download.content
  true = File.exists?(Path.join(root, "notes/demo.md"))
after
  File.rm_rf!(root)
end
```

Local creates its root if needed and rejects paths/symlinks escaping it.
Give an agent a dedicated root or appropriate read/write rules. A temporary
directory is suitable for experiments, not durable production notes.

### A memory store

`Filesystem.Store.new(store: store, namespace: parts)` stores one record per
file. A runtime namespace function can select the authenticated tenant.
The caller can also supply the store per invocation. Scope reads, writes and
maintenance operations consistently; see [Memory Files](memory_files.md).

Store-backed files use explicit namespaces and can be read without a model:

```elixir
alias BeamWeaver.Filesystem
store = BeamWeaver.Memory.ETS.new()
policy_backend = Filesystem.Store.new(store: store, namespace: ["acme", "policies"])
[%{error: nil}] = Filesystem.upload_files(policy_backend, [{"/refunds.md", "Refunds take five business days.
"}])
[%{content: "Refunds take five business days.
", error: nil}] = Filesystem.download_files(policy_backend, ["/refunds.md"])
```

### Mix backends by path

`Composite` uses the longest matching route prefix. Unmatched paths go to its
default, State unless configured otherwise. Listings/searches expose one
virtual tree, including nested mounts. Backend errors propagate rather than
being presented as complete partial results. State routes retain full virtual
paths in the thread's `files` map.

A routed state backend returns a file update for the parent state:

```elixir
scratch = BeamWeaver.Filesystem.Composite.new(routes: %{"/scratch/" => BeamWeaver.Filesystem.State.new()})
%{files_update: files} = BeamWeaver.Filesystem.write(scratch, "/scratch/draft.md", "Draft reply", state: %{})
Map.keys(files)
#=> ["/scratch/draft.md"]
```

The policy route uses the store above; unmatched paths use thread state:

```elixir
alias BeamWeaver.Filesystem
mixed = Filesystem.Composite.new(default: Filesystem.State.new(), routes: %{"/policies/" => policy_backend})
%{error: nil, file_data: %{content: policy_text}} = Filesystem.read(mixed, "/policies/refunds.md", state: %{})
true = policy_text =~ "five business days"
%{error: nil, files_update: notes} = Filesystem.write(mixed, "/notes/draft.md", "Ready for review.", state: %{})
true = Map.has_key?(notes, "/notes/draft.md")
```

### Run commands

LocalShell executes on your host and is not isolation. Commands receive a
restricted baseline environment plus `env:`; `inherit_env: true` passes the
whole application environment. Its command timeout is in seconds, unlike
agent/node timeouts. Output can be truncated to first/last portions.
See [Sandboxes](sandboxes.md) before exposing execution to an agent.

Use an explicit temporary working directory and inspect the command result:

```elixir
root = Path.join(System.tmp_dir!(), "beam-weaver-shell-#{System.unique_integer([:positive])}")

try do
  shell = BeamWeaver.Filesystem.LocalShell.new(root: root, timeout: 5)
  result = BeamWeaver.Filesystem.Executable.execute(shell, "printf ready")
  {0, "ready"} = {result.exit_code, result.output}
after
  File.rm_rf!(root)
end
```

### A sandbox

`Filesystem.Sandbox` adapts a started sandbox to file tools and execution.
Start long-lived sandboxes outside per-call declarations and stop them at the
end of their intended lifecycle. Mounted composite files are not automatically
visible to a command running in another backend.

## The file tools

| Tool | Behavior |
| --- | --- |
| `ls` | List immediate entries at `path` |
| `read_file` | Read `file_path`, with zero-based line `offset` and `limit` |
| `write_file` | Create or replace complete content |
| `edit_file` | Replace exact `old_string`; ambiguous matches need `replace_all` |
| `glob` | Match names/paths under a search root |
| `grep` | Find literal, case-sensitive text; optional file glob |
| `execute` | Run a command where supported |

Reads default to 2,000 lines and cap text at 80,000 characters on a line
boundary. Follow continuation notes for larger files. Images and PDFs can
return content blocks; other binary files return a notice. Search/list output
is also bounded and reports truncation; narrow the query rather than treating
that output as exhaustive.

Missing search roots return errors. Grep is not regex: use an appropriate
command tool for regex search where execution is permitted. Concurrent edits
to the same path in one model turn are rejected; shared application writers
still need coordination.

### Glob patterns

A pattern without `/` matches names at any depth below `path`. A path pattern
is relative to that root; `**/` spans directories and a leading `/` anchors
the immediate root. `*`, `?`, character classes, alternatives and escaping
are supported. Malformed patterns fail. Permission patterns have a narrower
syntax and do not support character classes.

## Permissions

Rules are ordered: **first match wins; unmatched paths are allowed**. End a
restricted allowlist with a broad deny rule:

```elixir
alias BeamWeaver.Filesystem.Permission

rules = [
  Permission.new(paths: ["/workspace/secrets/**"], mode: :deny),
  Permission.new(paths: ["/workspace/**"], mode: :allow),
  Permission.new(paths: ["/**"], mode: :deny)
]

true = Permission.allowed?(rules, :read, "/workspace/notes.md")
false = Permission.allowed?(rules, :read, "/workspace/secrets/key.txt")
false = Permission.allowed?(rules, :read, "/etc/hosts")
```

Pass rules through `filesystem_permissions`. `operations:` selects read/write;
`paths:` supports `*`, `?`, `**` and alternatives. Deny rules account for case
and normalization differences; allow rules match exactly. Tool checks validate
both the requested path and its canonical target where supported.

Permissions apply to the six file tools, not shell execution, custom tools or
direct application calls to `Filesystem`. They also filter denied paths from
list/search results. A denied search root must be replaced with an allowed
root, even when the pattern names an allowed descendant.

### Subagent permissions

Children using parent filesystem middleware inherit its rules unless their
spec overrides them. `permissions: []` removes that restriction. A child with
its own filesystem has its own boundary. The general-purpose worker receives
the parent workspace rules. Review inheritance before granting shared writes.

### Composite and executable backends

Rules match virtual paths including mount prefixes. A command can access what
its execution environment permits regardless of file-tool rules. Keep a
non-executable composite default when mounts contain protected data, or use a
separate execution environment with an appropriate policy.

Symlink resolution narrows path access but cannot identify every hard-link
alias or eliminate races from another process replacing links after a check.
Do not treat path rules as an operating-system sandbox.

Apply narrow rules before broad rules:

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

Normalization does not turn a forbidden path into an allowed path:

```elixir
for path <- ["/workspace/./.env", "/WORKSPACE/.ENV", "/workspace/../etc/hosts", "/Workspace/notes.md"],
    do: Permission.allowed?(rules, :read, path)

#=> [false, false, false, false]
```

## Change the large-result limits

Explicit `Filesystem` middleware can customize
`tool_token_limit_before_evict` (default 20,000) and
`human_message_token_limit_before_evict` (default 50,000); nil disables the
respective offload. Missing backend/permission options inherit declarations.
Large results are archived and replaced by previews; [Context Management](context_management.md)
explains retention and overflow recovery.

## Wrap a backend for policy checks

A wrapper can enforce content rules, quotas or logging before delegating to
an inner backend. Preserve canonical-path resolution if the inner backend
supports links. Cover every write path, including uploads performed by your
application; file-tool permission rules do not automatically cover them.

A wrapper can reject writes and edits while forwarding other operations. This example checks only write/edit content; bulk uploads are delegated unchanged:

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

Exercise the wrapper directly:

```elixir
fs = %MyApp.NoCardNumbers{inner: BeamWeaver.Filesystem.State.new()}
BeamWeaver.Filesystem.write(fs, "/notes/ada.md", "Card: 4111 1111 1111 1111").error
#=> "notes must not contain card numbers"
```

## Write a backend

Implement `BeamWeaver.Filesystem` operations: listing, reading, writing,
editing, glob/grep, upload/download and optional canonical paths. Return the
appropriate result struct with an `error` field on failure. Implement
`Filesystem.Executable` separately when command execution is supported.

### Check that permissions see your links

Link-capable adapters and wrappers should implement/forward `canonical_paths/3`.
`Filesystem.Conformance.check_symlinks/3` exercises permission behavior with
backend-created links. Use it in adapter tests; storage without links does
not need that check.

An executable adapter can delegate commands to an application-owned container:

```elixir
defmodule MyApp.ContainerExecutor do
  use BeamWeaver.Filesystem.Executable
  alias BeamWeaver.Filesystem.Executable.ExecuteResult
  defstruct [:sandbox]

  @impl true
  def id(workspace), do: "container:" <> workspace.sandbox.container

  @impl true
  def execute(workspace, command, opts) do
    result = BeamWeaver.Sandbox.execute(workspace.sandbox, command, opts)
    struct!(ExecuteResult, Map.from_struct(result))
  end
end

sandbox = BeamWeaver.Sandbox.Docker.new(image: "python:3.11-slim") |> BeamWeaver.Sandbox.Docker.start!()

try do
  workspace = struct!(MyApp.ContainerExecutor, sandbox: sandbox)
  result = BeamWeaver.Filesystem.Executable.execute(workspace, "printf ready", timeout: 5)
  {result.exit_code, result.output}
  # The result is asserted before the container is stopped.
  {0, "ready"} = {result.exit_code, result.output}
after
  BeamWeaver.Sandbox.Docker.stop(sandbox)
end
```

A wrapper must preserve canonical-path resolution. Run the conformance check on disposable files:

```elixir
root = Path.join(System.tmp_dir!(), "beam-weaver-links-#{System.unique_integer([:positive])}")

try do
  files = struct!(MyApp.NoCardNumbers, inner: BeamWeaver.Filesystem.Local.new(root: root))
  make_link = fn link, target -> File.ln_s!(Path.join(root, target), Path.join(root, link)) end
  :ok = BeamWeaver.Filesystem.Conformance.check_symlinks(files, make_link)
after
  File.rm_rf!(root)
end
```
