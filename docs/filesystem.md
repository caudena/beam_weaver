# Filesystem

Official Deep Agents calls this layer "backends." BeamWeaver names the public
surface `BeamWeaver.Filesystem` because the agent-facing capability is a virtual
filesystem: tools such as `ls`, `read_file`, `write_file`, `edit_file`, `glob`,
and `grep` operate on absolute POSIX-style paths regardless of where the bytes
are stored.

Use `filesystem` in the agent DSL or `:filesystem` with
`BeamWeaver.Agent.build/1`. Runtime `backend:` remains accepted as a
compatibility alias, but new BeamWeaver documentation should use
`filesystem:`.

{% hint style="info" %}
**Name Mapping**

Python Deep Agents `StateBackend`, `FilesystemBackend`, `StoreBackend`, and
`CompositeBackend` map to BeamWeaver `BeamWeaver.Filesystem.State`,
`BeamWeaver.Filesystem.Local`, `BeamWeaver.Filesystem.Store`, and
`BeamWeaver.Filesystem.Composite`.
{% endhint %}

## Quickstart

Thread-scoped scratch files are the default when a harness capability needs a
filesystem, but you can configure one explicitly:

```elixir
alias BeamWeaver.Agent
alias BeamWeaver.Filesystem

{:ok, agent} =
  Agent.build(
    model: "openai:gpt-5.4",
    filesystem: Filesystem.State.new(),
    tools: []
  )
```

Module-defined agents use the same setting:

```elixir
defmodule MyApp.Agent do
  use BeamWeaver.Agent

  model "openai:gpt-5.4"
  filesystem BeamWeaver.Filesystem.State.new()
end
```

Built-in filesystems:

| Filesystem | Use |
| --- | --- |
| `BeamWeaver.Filesystem.State` | Thread-scoped files stored in graph state. |
| `BeamWeaver.Filesystem.Local` | Trusted local disk under a configured root. |
| `BeamWeaver.Filesystem.LocalShell` | Local disk plus host shell execution. Unsafe outside controlled development. |
| `BeamWeaver.Filesystem.Store` | Durable files in a `BeamWeaver.Memory.Store` namespace. |
| `BeamWeaver.Filesystem.Composite` | Route different virtual path prefixes to different filesystems. |
| `BeamWeaver.Filesystem.Sandbox` | Adapt a `BeamWeaver.Sandbox` implementation into filesystem tools plus `execute`. |
| Custom module | Any struct implementing the `BeamWeaver.Filesystem` behaviour. |

## Tool Surface

Setting `filesystem` on an agent adds
`BeamWeaver.Agent.Middleware.Filesystem`, which contributes these model-visible
tools:

| Tool | Behavior |
| --- | --- |
| `ls` | List files and directories under an absolute virtual path. |
| `read_file` | Read a file with optional `offset` and `limit` line pagination. |
| `write_file` | Create a new file. Existing files are not overwritten. |
| `edit_file` | Replace exact strings in UTF-8 files. Multiple matches require `replace_all`. |
| `glob` | Find files matching a glob pattern. |
| `grep` | Search UTF-8 files for a literal string. |
| `execute` | Added only when the configured filesystem implements `BeamWeaver.Filesystem.Executable`. |

`read_file` returns UTF-8 text directly. Binary content is stored as base64 in
`BeamWeaver.Filesystem.FileData`; the tool currently presents base64 data as an
image content block. Use `download_files/3` from custom code when you need raw
bytes instead of model-visible content.

The middleware also offloads large tool results under
`/large_tool_results/<tool_call_id>` and oversized user messages under
`/conversation_history/...`, so the model can recover details later with
`read_file` or `grep`.

## State

`BeamWeaver.Filesystem.State` stores files in graph state under the `:files`
key by default.

```elixir
filesystem BeamWeaver.Filesystem.State.new()
```

Use it for scratch pads, intermediate artifacts, offloaded tool results, and
thread-scoped memory. Persistence depends on your graph or agent checkpointer:
files survive across turns in the same thread when state is checkpointed, but
they are not shared across threads.

You can change the state key:

```elixir
filesystem BeamWeaver.Filesystem.State.new(state_key: :workspace_files)
```

## Local

`BeamWeaver.Filesystem.Local` reads and writes real files under a trusted local
root:

```elixir
filesystem BeamWeaver.Filesystem.Local.new(root: "/path/to/project")
```

`root_dir:` is also accepted:

```elixir
filesystem BeamWeaver.Filesystem.Local.new(root_dir: "/path/to/project")
```

The agent still sees virtual absolute paths. For example, `/lib/app.ex` maps to
`/path/to/project/lib/app.ex`. BeamWeaver normalizes paths under the configured
root, rejects `..`, `~`, Windows drive paths, and unsafe symlink escapes.

{% hint style="warning" %}
**Local Files Are Real Files**

`BeamWeaver.Filesystem.Local` gives the agent direct read/write access under
the configured root. Use it for trusted local development, CI workspaces, or
mounted volumes. Do not expose it to arbitrary end users unless the surrounding
application enforces a real security boundary.
{% endhint %}

For most coding-assistant setups, wrap local project access in a composite
filesystem and keep internal agent artifacts in state:

```elixir
alias BeamWeaver.Filesystem

filesystem =
  Filesystem.Composite.new(
    default: Filesystem.State.new(),
    routes: %{
      "/workspace/" => Filesystem.Local.new(root: "/path/to/project")
    }
  )
```

This keeps `/large_tool_results/` and `/conversation_history/` out of your
project directory while still giving the agent `/workspace/...` access.

## Local Shell

`BeamWeaver.Filesystem.LocalShell` extends local filesystem access with the
`execute` tool:

```elixir
filesystem BeamWeaver.Filesystem.LocalShell.new(
  root: "/path/to/project",
  env: %{"MIX_ENV" => "test"},
  timeout: 120,
  max_output_bytes: 100_000
)
```

Commands run through `sh -c` in `root` with the current operating-system user's
permissions. `inherit_env: false` clears inherited environment variables before
applying `env`.

{% hint style="danger" %}
**Not A Sandbox**

`LocalShell` can run arbitrary host commands. Filesystem permissions only apply
to filesystem tools, not to shell command behavior. Use a sandbox filesystem or
your own command policy for untrusted input, production services, or multi-tenant
systems.
{% endhint %}

## Store

`BeamWeaver.Filesystem.Store` stores files in a `BeamWeaver.Memory.Store`
namespace. Use it for cross-thread durable files such as memories,
instructions, or shared reference material.

```elixir
alias BeamWeaver.Filesystem
alias BeamWeaver.Memory

store = Memory.ETS.new()

filesystem =
  Filesystem.Store.new(
    store: store,
    namespace: ["users", "user-123", "files"]
  )

{:ok, agent} =
  BeamWeaver.Agent.build(
    model: "openai:gpt-5.4",
    store: store,
    filesystem: filesystem
  )
```

For multi-user applications, use a namespace factory so each user or tenant gets
isolated storage:

```elixir
filesystem =
  BeamWeaver.Filesystem.Store.new(
    namespace: fn runtime ->
      user_id = get_in(runtime.context || %{}, [:user_id]) || "anonymous"
      ["users", user_id, "files"]
    end
  )
```

Namespace components cannot be empty and cannot contain `*` or `?`.

## Composite

`BeamWeaver.Filesystem.Composite` routes virtual path prefixes to different
filesystems. Longer prefixes win.

```elixir
alias BeamWeaver.Filesystem
alias BeamWeaver.Memory

store = Memory.ETS.new()

filesystem =
  Filesystem.Composite.new(
    default: Filesystem.State.new(),
    routes: %{
      "/workspace/" => Filesystem.Local.new(root: "/srv/project"),
      "/memories/" => Filesystem.Store.new(store: store, namespace: ["memories"])
    }
  )
```

Behavior:

| Virtual path | Routed to |
| --- | --- |
| `/notes/plan.md` | `State` default |
| `/workspace/lib/app.ex` | `Local` under `/srv/project/lib/app.ex` |
| `/memories/preferences.md` | `Store` key `preferences.md` in namespace `["memories"]` |

`ls`, `glob`, and `grep` preserve the original route prefixes in model-visible
results. If the default filesystem implements `BeamWeaver.Filesystem.Executable`,
the composite filesystem exposes `execute` through that default.

You can set `artifacts_root:` to move middleware-created offloading paths:

```elixir
filesystem =
  Filesystem.Composite.new(
    default: Filesystem.State.new(),
    artifacts_root: "/internal",
    routes: %{"/workspace/" => Filesystem.Local.new(root: "/srv/project")}
  )
```

## Sandbox

`BeamWeaver.Filesystem.Sandbox` adapts a `BeamWeaver.Sandbox` implementation to
the filesystem behaviour and executable extension:

```elixir
sandbox = BeamWeaver.Sandbox.local(root: "/tmp/agent-work")

filesystem =
  BeamWeaver.Filesystem.Sandbox.new(sandbox: sandbox)
```

Use a sandbox-backed filesystem when the agent needs shell execution but should
not run directly on the host. BeamWeaver includes local and Docker sandbox
building blocks; hard isolation depends on the sandbox implementation you
choose and how you deploy it.

See [Sandboxes](sandboxes.md) for sandbox lifecycle, file transfer APIs,
provider integration patterns, and security guidance.

## Permissions

Use `BeamWeaver.Filesystem.Permission` to allow or deny model-visible
filesystem-tool operations before they reach the backend:

```elixir
alias BeamWeaver.Filesystem.Permission

filesystem_permissions [
  Permission.new(
    operations: [:write],
    paths: ["/policies/**"],
    mode: :deny
  ),
  Permission.new(
    operations: [:read, :write],
    paths: ["/workspace/**"],
    mode: :allow
  )
]
```

Rules are evaluated in order and the first match wins. If no rule matches, the
operation is allowed. Permissions apply to `ls`, `read_file`, `write_file`,
`edit_file`, `glob`, and `grep`; list and search results are post-filtered so
denied paths do not appear in model-visible output.

Permissions are not a shell sandbox. If `execute` is available, enforce command
policy in the executable filesystem, sandbox, host environment, or
`BeamWeaver.Agent.Middleware.ShellTool`.

See [Filesystem Permissions](permissions.md) for rule ordering, read-only
memory, subagent overrides, composite routing, and sandbox caveats.

## Custom Filesystems

Implement `BeamWeaver.Filesystem` when you want to project S3, Postgres, a
remote API, or another storage system into the agent filesystem.

Required callbacks:

| Callback | Purpose |
| --- | --- |
| `ls/3` | Return immediate child entries for a virtual path. |
| `read/3` | Return `%BeamWeaver.Filesystem.ReadResult{}` with `%FileData{}`. |
| `write/4` | Create a new file. Return conflict errors instead of overwriting. |
| `edit/5` | Replace exact strings in a UTF-8 file. |
| `glob/3` | Return matching `%FileInfo{}` entries. |
| `grep/3` | Return `%GrepMatch{}` entries. |
| `upload_files/3` | Bulk upload path/content pairs. |
| `download_files/3` | Bulk download raw bytes or text. |

Normal "not found" and validation failures should return result structs with
`error:` set, not raise exceptions.

```elixir
defmodule MyApp.S3Filesystem do
  @behaviour BeamWeaver.Filesystem

  alias BeamWeaver.Filesystem

  defstruct [:bucket, prefix: ""]

  @impl true
  def ls(_backend, _path, _opts) do
    %Filesystem.LsResult{entries: []}
  end

  @impl true
  def read(_backend, _path, _opts) do
    %Filesystem.ReadResult{error: "file_not_found"}
  end

  @impl true
  def write(_backend, path, _content, _opts) do
    %Filesystem.WriteResult{path: path}
  end

  @impl true
  def edit(_backend, path, _old, _new, _opts) do
    %Filesystem.EditResult{path: path, occurrences: 0, error: "string not found"}
  end

  @impl true
  def glob(_backend, _pattern, _opts) do
    %Filesystem.GlobResult{matches: []}
  end

  @impl true
  def grep(_backend, _pattern, _opts) do
    %Filesystem.GrepResult{matches: []}
  end

  @impl true
  def upload_files(_backend, files, _opts) do
    Enum.map(files, fn {path, _content} -> %Filesystem.UploadResult{path: path} end)
  end

  @impl true
  def download_files(_backend, paths, _opts) do
    Enum.map(paths, fn path -> %Filesystem.DownloadResult{path: path, error: "file_not_found"} end)
  end
end
```

To expose `execute`, also implement `BeamWeaver.Filesystem.Executable` on the
same filesystem module:

```elixir
defmodule MyApp.RemoteExecutorFilesystem do
  @behaviour BeamWeaver.Filesystem
  @behaviour BeamWeaver.Filesystem.Executable

  # Filesystem callbacks omitted for brevity.

  @impl BeamWeaver.Filesystem.Executable
  def id(_backend), do: "remote-executor"

  @impl BeamWeaver.Filesystem.Executable
  def execute(_backend, command, _opts) do
    %BeamWeaver.Filesystem.Executable.ExecuteResult{
      exit_code: 0,
      output: "ran: #{command}"
    }
  end
end
```

## Policy Hooks

Path permissions are the first line of defense. For custom validation,
auditing, rate limits, or content inspection, wrap a filesystem and delegate to
the inner implementation. See
[Filesystem Permissions](permissions.md#policy-hooks) for a complete wrapper
example and the interaction between path rules, composite filesystems, and
executable backends.

## Unsupported Or Different From Official Deep Agents Docs

| Official Deep Agents docs | BeamWeaver behavior |
| --- | --- |
| Page and API call the concept "backends" | BeamWeaver documents the concept as `Filesystem`; `backend:` is only a runtime compatibility alias. |
| `create_deep_agent(model=..., backend=...)` | Use `BeamWeaver.Agent.build(model: ..., filesystem: ...)` or DSL `filesystem ...`. |
| `StateBackend` | `BeamWeaver.Filesystem.State`. |
| `FilesystemBackend(root_dir=..., virtual_mode=True)` | `BeamWeaver.Filesystem.Local.new(root: ... or root_dir: ...)`; BeamWeaver always exposes virtual absolute paths and does not have a `virtual_mode` option. |
| `LocalShellBackend` | `BeamWeaver.Filesystem.LocalShell`; it is unsafe host execution and should be treated separately from path permissions. |
| `StoreBackend` backed by LangGraph `BaseStore` | `BeamWeaver.Filesystem.Store` backed by `BeamWeaver.Memory.Store`. |
| `ContextHubBackend` for LangSmith Hub repos | Not currently implemented in BeamWeaver. Use `Store`, `Local`, or a custom filesystem. |
| Python `BackendProtocol` and result classes | Elixir `BeamWeaver.Filesystem` behaviour and structs such as `%ReadResult{}` and `%WriteResult{}`. |
| Backend factory and `BackendContext` migration notes | Not applicable to BeamWeaver. Use filesystem structs directly; namespace factories receive runtime when invoked through tools. |
| Multimodal extension table for images, video, audio, PDF, PPT/PPTX | BeamWeaver supports UTF-8 text, base64 binary reads, and raw byte downloads. It does not yet classify every media/document extension into provider-specific content blocks. |
| Python subclass examples for policy hooks | Use an Elixir wrapper module or `BeamWeaver.Filesystem.Permission`. |

## Related Guides

- [Agent Harness](agent_harness.md)
- [Context Engineering](context_engineering.md)
- [Filesystem Permissions](permissions.md)
- [Skills](skills.md)
- [Sandboxes](sandboxes.md)
- [Subagents](subagents.md)
- [Prebuilt Middleware](prebuilt_middleware.md)
- [Tools](tools.md)
- [Human-In-The-Loop](human_in_the_loop.md)
- [Memory](memory.md)
- [Long-Term Memory](long_term_memory.md)
