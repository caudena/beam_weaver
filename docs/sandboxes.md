# Sandboxes

Sandboxes let an agent work with files and run shell commands without giving it
direct access to your application host. In BeamWeaver, a sandbox is a
`BeamWeaver.Sandbox` implementation adapted into the agent filesystem through
`BeamWeaver.Filesystem.Sandbox`.

When a sandbox-backed filesystem is configured, the agent can use:

- `ls`, `read_file`, `write_file`, `edit_file`, `glob`, and `grep`
- `execute` for shell commands
- application-side file transfer with `upload_files` and `download_files`

{% hint style="warning" %}
**Sandbox Quality Depends On The Implementation**

`BeamWeaver.Sandbox.Local` is useful for development and tests, but it is not a
hardened isolation boundary. Use Docker with a hardened runtime, a VM, a remote
sandbox provider, or a custom `BeamWeaver.Sandbox` adapter for untrusted input
or production multi-tenant work.
{% endhint %}

## Why Use Sandboxes

Use a sandbox when an agent needs to:

- create, edit, and inspect code or data files,
- run package managers, tests, compilers, scripts, or CLIs,
- execute commands that should not run directly on the host,
- produce artifacts that your application retrieves after the run.

Sandboxes reduce blast radius. They do not make prompt injection harmless. An
attacker who controls context can still convince the agent to run commands
inside the sandbox, read sandbox files, or exfiltrate sandbox-accessible data if
network access exists.

## Basic Usage

Create a `BeamWeaver.Sandbox`, adapt it into a filesystem, and pass it to the
agent:

```elixir
alias BeamWeaver.Agent
alias BeamWeaver.Core.Message
alias BeamWeaver.Filesystem
alias BeamWeaver.Sandbox

sandbox = Sandbox.local(root: "/tmp/my-agent-workspace")

filesystem =
  Filesystem.Sandbox.new(sandbox: sandbox)

{:ok, agent} =
  Agent.build(
    model: "openai:gpt-5.4",
    filesystem: filesystem,
    system_prompt: "You are a coding assistant with sandboxed shell access."
  )

{:ok, _state} =
  Agent.invoke(agent, %{
    messages: [Message.user("Create a hello world script and run it.")]
  })
```

Because `BeamWeaver.Filesystem.Sandbox` implements
`BeamWeaver.Filesystem.Executable`, the filesystem middleware includes the
`execute` tool automatically.

## Docker Sandbox

`BeamWeaver.Sandbox.Docker` keeps the BeamWeaver runtime outside the container
and runs filesystem and command operations inside Docker:

```elixir
alias BeamWeaver.Filesystem
alias BeamWeaver.Sandbox

sandbox =
  Sandbox.Docker.new(
    image: "docker.io/library/python:3.11-slim",
    root: "/workspace",
    max_output_bytes: 100_000,
    runtime: "runsc"
  )

filesystem =
  Filesystem.Sandbox.new(sandbox: sandbox)
```

The Docker adapter starts a container on first use with:

- `--network none`
- `--cpus 1`
- `--memory 1g`
- `--pids-limit 256`
- `--workdir` set to the sandbox root

Plain Docker is still not a complete security boundary for hostile workloads.
For production, use a hardened runtime such as gVisor or Kata when available,
or implement a remote sandbox adapter backed by your infrastructure provider.

## Direct Sandbox API

You can call the sandbox directly from application code:

```elixir
alias BeamWeaver.Sandbox

sandbox = Sandbox.local(root: "/tmp/my-agent-workspace")

%Sandbox.WriteResult{error: nil} =
  Sandbox.write(sandbox, "/src/index.py", "print('hello')\n")

%Sandbox.ExecuteResult{exit_code: 0, output: output} =
  Sandbox.execute(sandbox, "python /tmp/my-agent-workspace/src/index.py")

%Sandbox.ReadResult{file_data: %{"content" => content, "encoding" => "utf-8"}} =
  Sandbox.read(sandbox, "/src/index.py")
```

For agent-facing use, prefer going through `BeamWeaver.Filesystem.Sandbox` so
the same virtual paths, file tools, and permissions pipeline are used.

## File Access Planes

There are two distinct file paths into a sandbox:

| Plane | Who uses it | BeamWeaver surface | Use |
| --- | --- | --- | --- |
| Agent filesystem tools | The model | `read_file`, `write_file`, `edit_file`, `ls`, `glob`, `grep`, `execute` | Work performed during the agent run. |
| File transfer API | Application code | `BeamWeaver.Sandbox.upload_files/3`, `download_files/3`, or `BeamWeaver.Filesystem.upload_files/3`, `download_files/3` | Seed inputs before a run and retrieve artifacts after a run. |

Seed files before invocation:

```elixir
alias BeamWeaver.Filesystem

filesystem = Filesystem.Sandbox.new(sandbox: sandbox)

[
  %Filesystem.UploadResult{path: "/src/index.py", error: nil},
  %Filesystem.UploadResult{path: "/pyproject.toml", error: nil}
] =
  Filesystem.upload_files(filesystem, [
    {"/src/index.py", "print('hello')\n"},
    {"/pyproject.toml", "[project]\nname = 'my-app'\n"}
  ])
```

Retrieve artifacts after the run:

```elixir
[%Filesystem.DownloadResult{path: "/src/index.py", content: content, error: nil}] =
  Filesystem.download_files(filesystem, ["/src/index.py"])
```

Use absolute virtual paths. BeamWeaver rejects path traversal such as `..`, `~`,
Windows drive paths, and null bytes.

## Command Execution

`execute` returns an exit code, output, optional error, and truncation flag:

```elixir
%BeamWeaver.Filesystem.Executable.ExecuteResult{
  exit_code: 0,
  output: "Python 3.11.8\n",
  error: nil,
  truncated: false
} =
  BeamWeaver.Filesystem.Executable.execute(filesystem, "python --version")
```

Timeouts must be integers from 1 to 3600 seconds:

```elixir
BeamWeaver.Filesystem.Executable.execute(
  filesystem,
  "pytest",
  timeout: 120
)
```

`BeamWeaver.Sandbox.Docker` truncates large command output according to
`max_output_bytes`. `BeamWeaver.Filesystem.Sandbox` exposes constants for the
current adapter limits used by the filesystem bridge:

```elixir
BeamWeaver.Filesystem.Sandbox.max_binary_bytes()
BeamWeaver.Filesystem.Sandbox.max_output_bytes()
```

For a narrower command surface, use `BeamWeaver.Agent.Middleware.ShellTool`
with an allow-list policy instead of exposing a general-purpose `execute` tool.

## Lifecycle And Scoping

BeamWeaver does not manage hosted sandbox lifecycles for you. Your application
chooses how sandboxes are created, reused, and cleaned up.

Common patterns:

| Scope | Pattern | Use |
| --- | --- | --- |
| Per invocation | Create a sandbox before invoking the agent, tear it down afterward. | One-off tasks and strongest cleanup guarantees. |
| Per thread | Store a sandbox ID by `thread_id` and reuse it for follow-up turns. | Coding sessions where files and dependencies should persist within one conversation. |
| Per agent or assistant | Store a sandbox ID by agent name or assistant ID. | Shared workspaces, cached dependencies, or long-lived coding environments. |

For per-thread reuse, resolve the sandbox from trusted runtime config or
application state before building or invoking the agent:

```elixir
thread_id = get_in(config, ["configurable", "thread_id"])
sandbox = MyApp.Sandboxes.get_or_create_for_thread!(thread_id)

{:ok, agent} =
  BeamWeaver.Agent.build(
    model: "openai:gpt-5.4",
    filesystem: BeamWeaver.Filesystem.Sandbox.new(sandbox: sandbox)
  )
```

Always configure cleanup. Docker containers, VM instances, and remote devboxes
consume resources until they are stopped or expire through provider TTL.

## Integration Patterns

### Agent Outside Sandbox

The BeamWeaver application runs on your server. The agent receives sandbox tools
and uses provider APIs through a `BeamWeaver.Sandbox` adapter.

This is the recommended BeamWeaver pattern because:

- model and application credentials stay outside the sandbox,
- agent logic can change without rebuilding sandbox images,
- sandbox failures do not erase the graph or agent state,
- multiple sandboxes can be used by different agents or tasks.

### Agent Inside Sandbox

You can also run the whole BeamWeaver application inside a container or remote
environment and talk to it over HTTP, RPC, or a queue. That pattern can mirror
local development, but it usually means secrets and agent state live inside the
sandbox. Treat that as a separate deployment architecture rather than a
BeamWeaver filesystem adapter.

## Custom Sandbox Adapters

Implement `BeamWeaver.Sandbox` to support another provider:

```elixir
defmodule MyApp.RemoteSandbox do
  @behaviour BeamWeaver.Sandbox

  alias BeamWeaver.Sandbox

  defstruct [:id, :client]

  def execute(%__MODULE__{} = sandbox, command, opts) do
    case MyProvider.run_command(sandbox.client, sandbox.id, command, opts) do
      {:ok, %{exit_code: code, output: output}} ->
        %Sandbox.ExecuteResult{exit_code: code, output: output}

      {:error, reason} ->
        %Sandbox.ExecuteResult{exit_code: nil, output: "", error: to_string(reason)}
    end
  end

  def upload_files(%__MODULE__{} = sandbox, files, _opts) do
    Enum.map(files, fn {path, content} ->
      case MyProvider.upload(sandbox.client, sandbox.id, path, IO.iodata_to_binary(content)) do
        :ok -> %Sandbox.UploadResult{path: path}
        {:error, reason} -> %Sandbox.UploadResult{path: path, error: to_string(reason)}
      end
    end)
  end

  # Implement write/read/edit/ls/glob/grep/download_files as provider-native
  # calls or by composing them from execute.
end
```

Then adapt it into the agent filesystem:

```elixir
filesystem =
  BeamWeaver.Filesystem.Sandbox.new(
    sandbox: %MyApp.RemoteSandbox{id: sandbox_id, client: client}
  )
```

## Security Considerations

Sandboxes protect the host from direct filesystem and shell access, but they do
not protect secrets placed inside the sandbox from the agent.

Do not put API keys, database credentials, cloud tokens, or production secrets
inside a sandbox. Prefer host-side tools that perform authenticated operations
without revealing credentials to the model or sandbox.

If a sandbox must access external services:

- use short-lived, least-privilege credentials,
- block or restrict outbound network access where possible,
- add human-in-the-loop approval before expensive or risky commands,
- audit command output and generated artifacts before using them,
- treat everything produced inside the sandbox as untrusted input.

`BeamWeaver.Filesystem.Permission` rules apply to model-visible file tools, but
they do not restrict `execute`. A shell command can read or write files through
the sandbox environment directly. Enforce command policy in the sandbox adapter,
with `ShellTool`, through provider network/filesystem controls, or with human
review.

## Related

- [Composed Agent Capabilities](agent_harness.md)
- [Filesystem](filesystem.md)
- [Filesystem Permissions](permissions.md)
- [Skills](skills.md)
- [Human-In-The-Loop](human_in_the_loop.md)
- [Tools](tools.md)
