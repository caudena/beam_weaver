# Filesystem Permissions

Official Deep Agents documents `FilesystemPermission` rules for controlling
which paths an agent can read or write. BeamWeaver supports the same model with
`BeamWeaver.Filesystem.Permission`, integrated into the normal agent
filesystem capability.

Use permissions when you need path-based allow/deny rules for the
model-visible filesystem tools. Use a filesystem wrapper, sandbox policy, tool
selection middleware, or custom tool logic when you need content inspection,
auditing, rate limits, command restrictions, or enforcement around custom tools.

{% hint style="warning" %}
**Permissions Are Not A Sandbox**

Permissions apply to `ls`, `read_file`, `write_file`, `edit_file`, `glob`, and
`grep`. They do not restrict custom tools, MCP tools, direct
`BeamWeaver.Filesystem` calls from application code, internal offloading writes,
or the `execute` tool on executable filesystems.
{% endhint %}

## Basic Usage

Pass permission rules through `filesystem_permissions:` when building an agent.
`permissions:` is accepted as a compatibility alias, but new BeamWeaver code
should prefer `filesystem_permissions:`.

```elixir
alias BeamWeaver.Agent
alias BeamWeaver.Filesystem
alias BeamWeaver.Filesystem.Permission

{:ok, agent} =
  Agent.build(
    model: "openai:gpt-5.4",
    filesystem: Filesystem.State.new(),
    filesystem_permissions: [
      Permission.new(
        operations: [:write],
        paths: ["/**"],
        mode: :deny
      )
    ]
  )
```

Module-defined agents use the `filesystem_permissions` DSL macro:

```elixir
defmodule MyApp.ReadOnlyAgent do
  use BeamWeaver.Agent

  alias BeamWeaver.Filesystem
  alias BeamWeaver.Filesystem.Permission

  model "openai:gpt-5.4"
  filesystem Filesystem.State.new()

  filesystem_permissions [
    Permission.new(operations: [:write], paths: ["/**"], mode: :deny)
  ]
end
```

Rules are evaluated in declaration order. The first rule whose operation and
path match wins. If no rule matches, the operation is allowed.

## Rule Structure

Each `BeamWeaver.Filesystem.Permission` rule has three fields:

| Field | Type | Description |
| --- | --- | --- |
| `:operations` | `[:read | :write]` or strings | Operations the rule applies to. `:read` covers `ls`, `read_file`, `glob`, and `grep`. `:write` covers `write_file` and `edit_file`. |
| `:paths` | list of strings | Absolute virtual path patterns such as `"/workspace/**"`. Paths must start with `/` and cannot contain `..` or `~`. |
| `:mode` | `:allow | :deny` or strings | Whether matching operations are allowed or denied. Defaults to `:allow`. |

Patterns support recursive `**`, `*`, `?`, and brace alternation such as
`"/data/{public,shared}.txt"`.

`Permission.new/1` validates operation names, modes, and path shape at
construction time:

```elixir
Permission.new(
  operations: [:read, :write],
  paths: ["/workspace/**"],
  mode: :allow
)
```

You can also pass atom-keyed maps, string-keyed maps, or keyword lists where a
permission list is expected; BeamWeaver normalizes them before evaluation.

## Examples

### Isolate To A Workspace Directory

Allow reads and writes only under `/workspace/` and deny everything else:

```elixir
filesystem_permissions [
  Permission.new(
    operations: [:read, :write],
    paths: ["/workspace/**"],
    mode: :allow
  ),
  Permission.new(
    operations: [:read, :write],
    paths: ["/**"],
    mode: :deny
  )
]
```

### Protect Specific Files

Put sensitive denies before broader allows:

```elixir
filesystem_permissions [
  Permission.new(
    operations: [:read, :write],
    paths: ["/workspace/.env", "/workspace/secrets/**"],
    mode: :deny
  ),
  Permission.new(
    operations: [:read, :write],
    paths: ["/workspace/**"],
    mode: :allow
  ),
  Permission.new(
    operations: [:read, :write],
    paths: ["/**"],
    mode: :deny
  )
]
```

### Read-Only Memory

Use a composite filesystem when some paths should be durable and others should
stay thread-scoped. Then deny writes to the durable memory prefixes:

```elixir
alias BeamWeaver.Filesystem
alias BeamWeaver.Filesystem.Permission
alias BeamWeaver.Memory

store = Memory.ETS.new()

filesystem =
  Filesystem.Composite.new(
    default: Filesystem.State.new(),
    routes: %{
      "/memories/" => Filesystem.Store.new(store: store, namespace: ["users", "user-123"]),
      "/policies/" => Filesystem.Store.new(store: store, namespace: ["orgs", "acme"])
    }
  )

{:ok, agent} =
  BeamWeaver.Agent.build(
    model: "openai:gpt-5.4",
    store: store,
    filesystem: filesystem,
    filesystem_permissions: [
      Permission.new(
        operations: [:write],
        paths: ["/memories/**", "/policies/**"],
        mode: :deny
      )
    ]
  )
```

The agent can still read memory and policy files, but `write_file` and
`edit_file` will return permission-denied tool results for those paths.

### Deny All Access

Block all built-in filesystem reads and writes:

```elixir
filesystem_permissions [
  Permission.new(
    operations: [:read, :write],
    paths: ["/**"],
    mode: :deny
  )
]
```

This does not remove the tools from the model-visible tool list; it makes calls
to those paths fail. Use `exclude_tools` when you want to hide filesystem tools
entirely. Capability profiles can store that policy for custom harness code, but
normal agent builds do not apply them automatically.

### Rule Ordering

Rules use first-match-wins semantics:

```elixir
correct_permissions = [
  Permission.new(operations: [:read, :write], paths: ["/workspace/.env"], mode: :deny),
  Permission.new(operations: [:read, :write], paths: ["/workspace/**"], mode: :allow),
  Permission.new(operations: [:read, :write], paths: ["/**"], mode: :deny)
]

incorrect_permissions = [
  Permission.new(operations: [:read, :write], paths: ["/workspace/**"], mode: :allow),
  Permission.new(operations: [:read, :write], paths: ["/workspace/.env"], mode: :deny),
  Permission.new(operations: [:read, :write], paths: ["/**"], mode: :deny)
]
```

In the incorrect version, `/workspace/.env` matches the broad workspace allow
rule first, so the later deny never applies.

## Subagent Permissions

Synchronous subagents can reuse the parent filesystem backend and permissions
when they compose filesystem middleware. A subagent does not get filesystem
tools merely because the parent has them. Add filesystem middleware to the
child, then use `:permissions` on the subagent spec to replace the inherited
permission list:

```elixir
alias BeamWeaver.Agent.Subagent
alias BeamWeaver.Filesystem.Permission

BeamWeaver.Agent.build(
  model: "openai:gpt-5.4",
  filesystem: BeamWeaver.Filesystem.State.new(),
  filesystem_permissions: [
    Permission.new(operations: [:read, :write], paths: ["/workspace/**"], mode: :allow),
    Permission.new(operations: [:read, :write], paths: ["/**"], mode: :deny)
  ],
  subagents: [
    Subagent.Spec.new(
      name: "auditor",
      description: "Read-only code reviewer.",
      system_prompt: "Review the code for issues. Do not edit files.",
      base_middleware: [BeamWeaver.Agent.Middleware.Filesystem],
      permissions: [
        Permission.new(operations: [:write], paths: ["/**"], mode: :deny),
        Permission.new(operations: [:read], paths: ["/workspace/**"], mode: :allow),
        Permission.new(operations: [:read], paths: ["/**"], mode: :deny)
      ]
    )
  ]
)
```

To explicitly give a subagent unrestricted filesystem-tool access, pass
`permissions: []` with filesystem middleware. To avoid exposing filesystem
tools, omit filesystem middleware from the child.

Async subagents run through their configured Agent Protocol client or custom
client. Their filesystem permissions are whatever the remote/background agent
uses; the supervisor's local `filesystem_permissions` do not automatically
govern a remote worker.

## Composite Filesystems

Permissions are evaluated against the virtual path the model uses. That means
they compose naturally with `BeamWeaver.Filesystem.Composite`:

```elixir
filesystem =
  BeamWeaver.Filesystem.Composite.new(
    default: BeamWeaver.Filesystem.State.new(),
    routes: %{
      "/workspace/" => BeamWeaver.Filesystem.Local.new(root: "/srv/project"),
      "/memories/" => BeamWeaver.Filesystem.Store.new(namespace: ["memories"])
    }
  )

filesystem_permissions [
  Permission.new(operations: [:write], paths: ["/memories/**"], mode: :deny),
  Permission.new(operations: [:read, :write], paths: ["/workspace/**"], mode: :allow),
  Permission.new(operations: [:read, :write], paths: ["/**"], mode: :deny)
]
```

`ls`, `glob`, and `grep` results are post-filtered after the filesystem returns
matches, so denied paths are removed from model-visible listings and search
results.

## Executable Filesystems And Sandboxes

If a filesystem implements `BeamWeaver.Filesystem.Executable`, the filesystem
middleware exposes `execute`. Permission rules do not apply to `execute`,
because a shell command can read, write, or exfiltrate files through mechanisms
outside the built-in file tools.

For executable setups:

- Use `BeamWeaver.Filesystem.Sandbox` or another real isolation layer for
  untrusted work.
- Prefer a non-executable default filesystem when using `Composite` with
  sensitive routed storage.
- Gate `execute` with human-in-the-loop, tool selection, or a custom command
  policy.
- Treat `BeamWeaver.Filesystem.LocalShell` as trusted development-only host
  execution.

See [Sandboxes](sandboxes.md) for the execution boundary and sandbox lifecycle
patterns.

Unlike the official Python docs, BeamWeaver does not raise at agent
construction time when a composite filesystem has an executable default and a
permission pattern touches the default route. The rule still applies to
filesystem tools, but it cannot secure shell execution.

## Policy Hooks

For custom validation, wrap the filesystem and enforce your policy before
delegating to the inner implementation:

```elixir
defmodule MyApp.GuardedFilesystem do
  @behaviour BeamWeaver.Filesystem

  alias BeamWeaver.Filesystem

  defstruct [:inner, deny_prefixes: []]

  defp denied?(%__MODULE__{deny_prefixes: prefixes}, path) do
    Enum.any?(prefixes, &String.starts_with?(path, &1))
  end

  @impl true
  def write(%__MODULE__{} = backend, path, content, opts) do
    if denied?(backend, path) do
      %Filesystem.WriteResult{path: path, error: "writes denied under #{path}"}
    else
      Filesystem.write(backend.inner, path, content, opts)
    end
  end

  @impl true
  def edit(%__MODULE__{} = backend, path, old, new, opts) do
    if denied?(backend, path) do
      %Filesystem.EditResult{path: path, error: "edits denied under #{path}"}
    else
      Filesystem.edit(backend.inner, path, old, new, opts)
    end
  end

  # Delegate ls/read/glob/grep/upload_files/download_files in the same style.
end
```

Use this pattern when the decision depends on content, tenant policy, quotas,
auditing, or any context beyond a path glob.

## Unsupported Or Different From Official Deep Agents Docs

| Official Deep Agents docs | BeamWeaver behavior |
| --- | --- |
| `FilesystemPermission` from `deepagents` | `BeamWeaver.Filesystem.Permission`. |
| `create_deep_agent(..., permissions=...)` | Use `filesystem_permissions:` or DSL `filesystem_permissions [...]`; `permissions:` is a runtime compatibility alias. |
| Permissions require `deepagents>=0.5.2` | Version note is Python-specific and does not apply to BeamWeaver. |
| Permissions do not apply to sandbox backends | BeamWeaver applies rules to built-in file tools even when the filesystem is `BeamWeaver.Filesystem.Sandbox`; rules still do not restrict `execute`. |
| Composite backend with sandbox default raises `NotImplementedError` for broad paths | BeamWeaver does not perform this construction-time rejection. Treat `execute` as the separate boundary. |
| Custom tools and MCP tools are outside permission scope | Same. BeamWeaver permissions only govern the built-in filesystem tools. |
| Backend policy hooks via Python subclassing | Use an Elixir filesystem wrapper module, custom middleware, or command policy. |
| `permissions: []` on a subagent grants unrestricted access | Same for synchronous generated subagents. Omitted `:permissions` inherits the parent; an explicit empty list replaces it. |

## Related Guides

- [Filesystem](filesystem.md)
- [Composed Agent Capabilities](agent_harness.md)
- [Subagents](subagents.md)
- [Async Subagents](async_subagents.md)
- [Human-In-The-Loop](human_in_the_loop.md)
- [Prebuilt Middleware](prebuilt_middleware.md)
- [Tools](tools.md)
