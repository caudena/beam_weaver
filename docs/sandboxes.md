# Sandboxes

A sandbox is a workspace where an agent keeps files and runs shell commands,
away from your application's own files and processes. Use one when an agent
needs to run scripts, tests or command-line tools.

```elixir
defmodule MyApp.Workspace do
  def root, do: Path.join(System.tmp_dir!(), "acme_workspace")
  def sandbox, do: BeamWeaver.Sandbox.local(root: root())
end

defmodule MyApp.SupportResearcher do
  use BeamWeaver.Agent

  alias BeamWeaver.Models.FakeChatModel

  model "fake:chat",
    responses: [
      FakeChatModel.tool_call("execute", %{"command" => "grep -c refunded orders.csv"}),
      "You had 2 refunds this year."
    ]

  system_prompt "Answer questions about the customer's order export, orders.csv."
  filesystem BeamWeaver.Filesystem.Sandbox.new(sandbox: MyApp.Workspace.sandbox())
end

csv = "order,status\nA-1001,refunded\nA-1002,shipped\nA-1003,refunded\n"
BeamWeaver.Sandbox.upload_files(MyApp.Workspace.sandbox(), [{"/orders.csv", csv}])

{:ok, result} = MyApp.SupportResearcher.invoke(%{messages: ["How many refunds did I get this year?"]})
result.messages |> Enum.find(&(&1.role == :tool)) |> BeamWeaver.Core.Message.text()
#=> "2\n[Command succeeded with exit code 0]"
```

`BeamWeaver.Filesystem.Sandbox` makes the sandbox the agent's filesystem, so
the agent gets the file tools of [Filesystem](filesystem.md) and an `execute`
tool that runs a command in the sandbox and returns its output and exit code.
Your application put `orders.csv` in before the run.

An agent that runs commands can do anything those commands can. A sandbox
confines them to a workspace you can throw away, with limits such as no
network. It doesn't make prompt injection harmless: whoever writes the model's
input can still run commands inside it ([Security](#security)).

## Local sandbox

`BeamWeaver.Sandbox.local/1` keeps the files in the `root:` directory (by
default `beam_weaver_sandbox` in the system's temp directory) and runs commands
there with `sh`. File paths are absolute inside the sandbox: `/orders.csv` is
`orders.csv` in `root`, and `..` or `~` are refused. Commands start in `root`,
so they use relative paths. `max_output_bytes:` (default 512,000) cuts output.

Commands don't see your application's environment variables, such as provider
API keys. They get `PATH`, `HOME`, `LANG`, the `LC_*` variables, `TMPDIR`,
`USER` and `SHELL`, plus what you pass in `env:`; `inherit_env: true` gives
them the whole environment instead:

```elixir
sandbox = BeamWeaver.Sandbox.local(root: MyApp.Workspace.root(), env: %{"REPORT_YEAR" => "2026"})
BeamWeaver.Sandbox.execute(sandbox, "echo $REPORT_YEAR ${OPENAI_API_KEY:-no key}").output
#=> "2026 no key\n"
```

{% hint style="warning" %}
**A local sandbox is not isolation.** Its commands run on your machine as the
user that runs your application, and can read and change anything that user
can, including files that hold secrets. Use it for development and tests; run
untrusted work in Docker or a hosted sandbox.
{% endhint %}

## Docker sandbox

`BeamWeaver.Sandbox.Docker` runs commands and file operations in a container,
while your application stays outside. A module agent evaluates its
`filesystem` declaration on every run, so it can fetch a sandbox your
application started. Here a process in your supervision tree owns the
container: it starts it with your application, and the container goes away
when the process stops.

```elixir
defmodule MyApp.SandboxOwner do
  use GenServer

  alias BeamWeaver.Sandbox.Docker

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def sandbox, do: GenServer.call(__MODULE__, :sandbox)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    {:ok, opts |> Docker.new() |> Docker.start!()}
  end

  @impl true
  def handle_call(:sandbox, _from, sandbox), do: {:reply, sandbox, sandbox}

  @impl true
  def terminate(_reason, sandbox), do: Docker.stop(sandbox)
end

defmodule MyApp.SupportResearcher do
  use BeamWeaver.Agent

  model "anthropic:claude-sonnet-4-6"
  filesystem BeamWeaver.Filesystem.Sandbox.new(sandbox: MyApp.SandboxOwner.sandbox())
end
```

Start it in your supervision tree with the container's options, such as
`{MyApp.SandboxOwner, image: "docker.io/library/python:3.12-slim", runtime: "runsc", mounts: [%{source: "/srv/acme/workspace", target: "/workspace"}]}`.
`BeamWeaver.Sandbox.Docker.new/1` only describes the container; every
operation runs in the one container that `start!/1` started, and on a sandbox
that isn't started it returns `error: "container_not_started"`. The process
that calls `start!/1` owns the container: with `remove: true` (the default)
the container is removed when that process exits, so start it in a
long-lived process like this one. `remove: false` keeps it running until you
call `stop/1`.

`BeamWeaver.Sandbox.Docker.start!/1` runs `docker run --init` with no network,
one CPU, 1 GB of memory and at most 256 processes, in `/workspace`; `network:`,
`cpus:`, `memory:`, `pids_limit:` and `root:` change that, and `read_only:`,
`tmpfs:`, `cap_drop:` and `security_opts:` harden it. Mounts need absolute
host paths. The file tools run `find`, `grep` and `python3` in the container,
so pick an image that has them. Plain Docker shares the host's kernel; for
hostile workloads use a hardened runtime such as gVisor (`runtime: "runsc"`).

## Use a sandbox directly

The functions of `BeamWeaver.Sandbox` work on any sandbox. Each returns a
result struct with an `error` field instead of raising:

```elixir
alias BeamWeaver.Sandbox

sandbox = MyApp.Workspace.sandbox()
%Sandbox.WriteResult{error: nil} = Sandbox.write(sandbox, "/scripts/count.sh", "grep -c refunded orders.csv\n")

Sandbox.execute(sandbox, "sh scripts/count.sh", timeout: 10)
#=> %Sandbox.ExecuteResult{exit_code: 0, output: "2\n", error: nil, truncated: false}
```

`write/4` refuses a file that exists, `edit/5` replaces an exact string,
`read/3` takes `offset:` and `limit:` in lines, and `ls/3`, `glob/3` and
`grep/3` search. `upload_files/3` and `download_files/3` move many files at
once, to seed a run and collect its results. Every `execute/3` emits
`[:beam_weaver, :sandbox, :execute, :start]` and `:stop`, `:timeout` or
`:exception` telemetry events, with secrets redacted ([Tracing](tracing.md)).

## Command timeouts

`execute` takes `timeout:` in seconds, from 1 to 3600 (default 120), and so
does the agent's `execute` tool. A command that runs longer is stopped
together with every process it started: its process group gets SIGTERM, then
SIGKILL one second later, inside the container for Docker. The result has
`exit_code: 124` and `error: "timeout"`. The agent's `execute` tool gives the
model a command's output followed by its exit code, such as
`[Command failed with exit code 1]`, and after a timeout an error that says the
command was stopped. The shell tool below counts its `timeout` in
milliseconds and stops commands the same way:

```elixir
slow = BeamWeaver.Tools.Shell.new(policy: [allow: ["sleep"], timeout: 50])
BeamWeaver.Core.Tool.invoke(slow, %{"command" => "sleep 5"})
#=> {:error, %BeamWeaver.Core.Error{type: :shell_timeout}}
```

## Shell tool and policies

When a model should run a few known commands rather than anything, give it
`BeamWeaver.Tools.Shell`. Every command must pass a `BeamWeaver.ShellPolicy`.
A string rule allows that command with any arguments, and a regex rule any
command line it matches, but both only for a single command: `;`, `&&`, `|`,
`$(...)` and backticks outside quotes are refused. `deny` rules win over
`allow`:

```elixir
policy = BeamWeaver.ShellPolicy.new!(allow: ["grep", "wc -l"], deny: [~r/--recursive/])
commands = ["grep -c refunded orders.csv", "grep -c x a; rm a", "wc orders.csv", "grep --recursive x /"]

Enum.map(commands, &BeamWeaver.ShellPolicy.allowed?(policy, &1))
#=> [true, false, false, false]
```

To allow a command line that chains commands, write a regex that matches all
of it, anchored at both ends, and set `allow_compound: true`.

```elixir
build = BeamWeaver.ShellPolicy.new!(allow: [~r/^mix compile && mix test$/], allow_compound: true)
Enum.map(["mix compile && mix test", "mix compile && rm -rf ~"], &BeamWeaver.ShellPolicy.allowed?(build, &1))
#=> [true, false]
```

### Commands that run other commands

The policy reads a command line the way the shell does and checks the commands
that actually run, so a rule can't be walked around with a wrapper:

* Wrappers that only change how a command runs are looked through: in
  `timeout 30 pytest -q`, `env CI=1 make`, `FOO=1 make` or `sh -c 'make'` the
  _wrapped_ command must be allowed, and the wrapper (`timeout`, `env`, `sh`,
  and also `command`, `exec`, `nohup`, `time`, `nice`, `stdbuf`, `flock`,
  `busybox`, `eval`, `trap`) needs no rule of its own. An assignment before
  the command may hold glob characters, as in `DEBUG=* make`: no shell
  expands them there.
* Commands that run another as a different user, on another host, or once per
  input need a rule _and_ the command they run must be allowed: `sudo`, `doas`,
  `ssh` (its remote command), `xargs`, `find -exec`, `parallel`, `watch`,
  `script`. `"sudo apt-get update"` allows that line; `"sudo"` alone allows
  nothing.
* Deny rules see every command at every level, also without its leading
  variable assignments and with its words unquoted, so a `"rm "` rule catches
  `sh -c 'rm x'`, `FOO=1 rm x`, `\rm x` and `/bin/rm x`.

```elixir
policy = BeamWeaver.ShellPolicy.new!(allow: ["pytest", "make"], deny: ["rm "])
cmds = ["timeout 30 pytest -q", "env FOO=1 make", "DEBUG=* make", "sh -c 'make'", "sh -c 'rm -rf .'", "timeout 5 rm -rf ."]
Enum.map(cmds, &BeamWeaver.ShellPolicy.allowed?(policy, &1))
#=> [true, true, true, true, false, false]
```

### Code the policy can't read

Some commands run code that can't be read from the command line, and the
policy refuses them even when a rule for the program matches: inline
interpreter code (`python -c`, `perl -e`, `node -e`, an `awk` program that
calls `system()`, a `sed` script with the `e` flag, `vim -c`), a script from a
file or standard input (`bash build.sh`, `source`, `sh` with no `-c`,
`curl … | sh`), a command built at run time (`$TOOL args`, `sh -c "$SCRIPT"`,
a name with a glob or brace expansion), shells with a syntax of their own
(`zsh`, `fish`, `csh`, `pwsh`), setting a variable that makes programs load or
run other code (`PATH`, `LD_PRELOAD`, `BASH_ENV`, `GIT_SSH_COMMAND`, …) or any
variable to text with spaces or shell syntax in it (`FOO='a b'`, or
`env DEBUG=*`, where the shell expands the `*` to file names), and bash
arithmetic on a variable. `BeamWeaver.ShellPolicy.check/2` returns a
`:shell_command_rejected` error whose message says which.

To allow one, write a rule that spells out the part the policy can't read —
`"python3 -c"` allows inline Python, `"bash scripts/ci.sh"` runs that script —
or set `allow_opaque: true`, which lets ordinary rules allow such commands.
Deny rules can't see inside them either way; `allow` the exact commands
instead.

```elixir
tools = BeamWeaver.ShellPolicy.new!(allow: ["python3 report.py", "python3 -c"])
Enum.map(["python3 report.py", "python3 -c 'print(1)'", "python3 evil.py"], &BeamWeaver.ShellPolicy.allowed?(tools, &1))
#=> [true, true, false]
```

A policy is a guard rail, not a sandbox. The policy reads a command line; it
can't see what a command _does_ once it runs — the code in a script, a
`Makefile` or a test suite it is allowed to run, the options of some programs
that run other commands (`docker run`, `npx`), or a program copied under
another name. Keep `allow` rules to the exact commands the model needs, treat
`deny` as a backstop, and run untrusted work in a real sandbox (Docker or a
hosted provider).

The tool runs each command in a new shell, in the policy's `cwd` (or your
application's directory). List it in an agent's `tools` like any tool; the
model reads the command, its exit `status` and its `output` as JSON:

```elixir
shell = BeamWeaver.Tools.Shell.new(policy: [allow: ["grep", "wc -l"], cwd: MyApp.Workspace.root()])

{:ok, %{output: output}} = BeamWeaver.Core.Tool.invoke(shell, %{"command" => "grep -c refunded orders.csv"})
{output, BeamWeaver.Core.Tool.invoke(shell, %{"command" => "rm orders.csv"})}
#=> {"2\n", {:error, %BeamWeaver.Core.Error{type: :shell_command_rejected}}}
```

| Policy option | Meaning |
| --- | --- |
| `allow`, `deny` | Command prefixes or regexes to allow (required) and to refuse. A wrapped command is checked against these too. |
| `allow_compound` | `true` lets regex rules allow command lines that chain commands (default `false`). |
| `allow_opaque` | `true` lets ordinary rules allow commands that run code the policy can't read, such as `python -c` or `bash script.sh` (default `false`). |
| `cwd`, `env` | The directory commands run in, and variables to set. |
| `inherit_env` | `true` gives commands your application's whole environment; by default they get only `PATH`, `HOME`, `LANG`, `LC_*`, `TMPDIR`, `USER`, `SHELL` and `env`. |
| `timeout` | Milliseconds before a command is stopped (default 5,000). |
| `max_output_bytes` | Where output is cut (default 20,000). `redactions:` replaces `{regex, text}` in it. |
| `executor` | A module (or struct) implementing `BeamWeaver.Tools.Shell.Executor` that runs the one-shot tool's commands elsewhere, such as in a container. The tool checks `allow`/`deny` before calling it. The session below runs on the host and refuses to start with a custom executor. |

`BeamWeaver.Agent.Middleware.ShellTool` gives an agent the tool, named
`shell`, as one shell session per run, so `cd` and `export` carry over between
commands. It requires a `policy:` (`ShellTool.new/1` raises an
`ArgumentError` without one), and its `startup_commands:` must pass it too.
The session is supervised and, for a run with a thread id, kept for that thread
across a human-review pause, so a resumed run reuses it (or lazily starts a
fresh one when it has gone). A session with no command for `:idle_timeout`
milliseconds (default 15 minutes) stops on its own, so a run that never
finishes doesn't leave it behind:

```elixir
middleware [
  {BeamWeaver.Agent.Middleware.ShellTool, policy: [allow: ["grep", "wc -l"]], workspace_root: "/srv/acme/workspace"}
]
```

## Custom sandbox adapters

For another service, such as a hosted sandbox provider, write an adapter: a
struct with what you need to reach it and the nine callbacks of
`use BeamWeaver.Sandbox`. This one wraps a local sandbox and adds an id to each
command's metadata, as an adapter adds its provider's sandbox id:

```elixir
defmodule MyApp.TaggedSandbox do
  use BeamWeaver.Sandbox

  alias BeamWeaver.Sandbox

  defstruct [:id, :inner]

  @impl true
  def execute(sandbox, command, opts) do
    result = Sandbox.execute(sandbox.inner, command, opts)
    %{result | metadata: Map.put(result.metadata, :sandbox_id, sandbox.id)}
  end

  @impl true
  def write(sandbox, path, content, opts), do: Sandbox.write(sandbox.inner, path, content, opts)
  @impl true
  def read(sandbox, path, opts), do: Sandbox.read(sandbox.inner, path, opts)
  @impl true
  def edit(sandbox, path, old, new, opts), do: Sandbox.edit(sandbox.inner, path, old, new, opts)
  @impl true
  def ls(sandbox, path, opts), do: Sandbox.ls(sandbox.inner, path, opts)
  @impl true
  def glob(sandbox, pattern, opts), do: Sandbox.glob(sandbox.inner, pattern, opts)
  @impl true
  def grep(sandbox, pattern, opts), do: Sandbox.grep(sandbox.inner, pattern, opts)
  @impl true
  def upload_files(sandbox, files, opts), do: Sandbox.upload_files(sandbox.inner, files, opts)
  @impl true
  def download_files(sandbox, paths, opts), do: Sandbox.download_files(sandbox.inner, paths, opts)
  @impl true
  def canonical_paths(sandbox, paths, opts), do: Sandbox.canonical_paths(sandbox.inner, paths, opts)
end
```

The optional `canonical_paths/3` returns the path of the file each path
reaches with the sandbox's symlinks followed, which
[filesystem permissions](filesystem.md#permissions) check too; a sandbox
without it is taken to have no links. To test it, run
`BeamWeaver.Filesystem.Conformance.check_symlinks/3` on
`BeamWeaver.Filesystem.Sandbox.new(sandbox: adapter)`, as
[Filesystem](filesystem.md#check-that-permissions-see-your-links) shows. Give
the adapter to an agent with `BeamWeaver.Filesystem.Sandbox.new/1`, like any
sandbox. The registry in the next section builds them.

## Provider registry

When the kind of sandbox comes from configuration, register providers in a
`BeamWeaver.Sandbox.Registry` and build sandboxes by provider id. A provider
implements `BeamWeaver.Sandbox.Provider`; its `build/2` gets the provider spec,
with your `config`, and the build options. This one builds the tagged sandbox
above, one directory per customer:

```elixir
defmodule MyApp.TenantSandboxes do
  @behaviour BeamWeaver.Sandbox.Provider

  @impl true
  def build(spec, opts) do
    id = Keyword.fetch!(opts, :sandbox_id)
    {:ok, %MyApp.TaggedSandbox{id: id, inner: Sandbox.local(root: Path.join(spec.config.base_dir, id))}}
  end
end

alias BeamWeaver.Sandbox.Registry

tenants = %{
  id: :tenants,
  module: MyApp.TenantSandboxes,
  config: %{base_dir: Path.join(MyApp.Workspace.root(), "tenants")},
  capabilities: %{sandbox_id: true}
}

{:ok, registry} = Registry.new(providers: [tenants])
{:ok, sandbox} = Registry.build(registry, :tenants, sandbox_id: "sbx_ada")
{Sandbox.execute(sandbox, "echo ok").metadata.sandbox_id, Registry.build(registry, :local, sandbox_id: "sbx_ada")}
#=> {"sbx_ada", {:error, %BeamWeaver.Core.Error{type: :unsupported_sandbox_provider_option}}}
```

`capabilities` lists the lifecycle options a provider accepts (`sandbox_id`,
`snapshot`, `mounts`, `working_dir`). The registry refuses the others, as for
its built-in `local` provider, and checks that `build/2` returned a sandbox.

## Interpreters

An interpreter keeps state between pieces of code, such as a language
runtime's variables. BeamWeaver runs it in a session process that limits each
call to a `timeout` and turns crashes into errors. You write the adapter, a
`BeamWeaver.Sandbox.Interpreter`; this one keeps a running refund total:

```elixir
defmodule MyApp.RefundTally do
  @behaviour BeamWeaver.Sandbox.Interpreter

  @impl true
  def open(_opts), do: {:ok, 0}

  @impl true
  def eval(total, "refund " <> amount, _opts) do
    total = total + String.to_integer(amount)
    {:ok, total, total}
  end

  def eval(total, "total", _opts), do: {:ok, total, total}

  @impl true
  def snapshot(total, _opts), do: {:ok, total}

  @impl true
  def restore(total, _opts), do: {:ok, total}
end

alias BeamWeaver.Sandbox.Interpreter.Session

{:ok, session} = Session.start(adapter: MyApp.RefundTally, timeout: 1_000)
{:ok, 25} = Session.eval(session, "refund 25")
{:ok, snapshot} = Session.snapshot(session)
{:ok, 65} = Session.eval(session, "refund 40")

{:ok, restored} = Session.start(adapter: MyApp.RefundTally)
:ok = Session.restore(restored, snapshot)
answers = {Session.eval(restored, "total"), Session.eval(restored, "delete everything")}

Enum.each([session, restored], &Session.close/1)
answers
#=> {{:ok, 25}, {:error, %BeamWeaver.Core.Error{type: :interpreter_execution_failed}}}
```

The restored session started from the snapshot's total. A call that fails or
runs past `timeout` (`:interpreter_timeout`) leaves the state as it was. A
snapshot is plain data, up to `max_snapshot_bytes` (default 1,000,000), that
you can store, for example in agent state. Start sessions with `start_link/1`
under a supervisor, and call `Session.eval/3` from a [tool](tools.md).

## Lifecycle and cleanup

BeamWeaver doesn't create sandboxes for you. Decide how long each one lives,
such as one per run, per thread or per customer, and remove it after: delete a
local sandbox's `root`, and remove a container with
`BeamWeaver.Sandbox.Docker.stop/1`. A container started with `remove: true`
also goes when the process that started it exits; after the whole VM crashed,
remove it with `stop_owned/2`, which checks that its `labels:` still match. For a sandbox per thread or customer,
build the agent at runtime ([Agents built at runtime](agents.md#agents-built-at-runtime)).
Docker's `start_exec/3`, `read_exec/4` and `stop_exec/3` run long commands
whose output must outlive the calling process. This page cleans up with:

```elixir
File.rm_rf!(MyApp.Workspace.root())
File.exists?(MyApp.Workspace.root())
#=> false
```

## Security

- Keep secrets out of the sandbox's files and environment; do authenticated
  work in your own [tools](tools.md). Local commands don't inherit your
  application's environment unless you pass `inherit_env: true`. Block network
  access where you can.
- [Filesystem permissions](filesystem.md#permissions) limit the file tools,
  not `execute`. Pause before commands that matter with
  `interrupt_on %{"execute" => true}` ([Human-in-the-Loop](human_in_the_loop.md)).
- Treat everything that comes out of a sandbox as untrusted input.

## Reference

- [`BeamWeaver.Sandbox`](https://hexdocs.pm/beam_weaver/BeamWeaver.Sandbox.html): the sandbox behaviour and functions
- [`BeamWeaver.Sandbox.Local`](https://hexdocs.pm/beam_weaver/BeamWeaver.Sandbox.Local.html): a sandbox in a local directory
- [`BeamWeaver.Sandbox.Docker`](https://hexdocs.pm/beam_weaver/BeamWeaver.Sandbox.Docker.html): a sandbox in a Docker container
- [`BeamWeaver.Filesystem.Sandbox`](https://hexdocs.pm/beam_weaver/BeamWeaver.Filesystem.Sandbox.html): a sandbox as an agent's filesystem
- [`BeamWeaver.Sandbox.Registry`](https://hexdocs.pm/beam_weaver/BeamWeaver.Sandbox.Registry.html): sandbox providers by id
- [`BeamWeaver.Sandbox.Interpreter.Session`](https://hexdocs.pm/beam_weaver/BeamWeaver.Sandbox.Interpreter.Session.html): interpreter sessions
- [`BeamWeaver.Tools.Shell`](https://hexdocs.pm/beam_weaver/BeamWeaver.Tools.Shell.html): the policy-checked shell tool
- [`BeamWeaver.ShellPolicy`](https://hexdocs.pm/beam_weaver/BeamWeaver.ShellPolicy.html): shell command rules
- [`BeamWeaver.Agent.Middleware.ShellTool`](https://hexdocs.pm/beam_weaver/BeamWeaver.Agent.Middleware.ShellTool.html): the shell tool as a session per run
