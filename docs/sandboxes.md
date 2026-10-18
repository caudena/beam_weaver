# Sandboxes and Command Execution

Choose an execution boundary before giving an agent command access. A local
workspace runs as your application user. Docker provides a container boundary;
its configuration determines network, filesystem and resource access. A shell
allowlist is a command policy, not operating-system isolation.


Run this page’s examples in order in one IEx session; later blocks reuse the modules and values defined earlier.

## Run an agent in Docker

Complete [Installation](installation.md) and start Docker. The image must
contain Python 3 and the GNU utilities used by file operations. This example
starts one disposable container, makes a real OpenAI call and checks the
command's exit code and output before removing the container.

```elixir
alias BeamWeaver.Sandbox
sandbox = Sandbox.Docker.new(image: "python:3.12-slim") |> Sandbox.Docker.start!()

try do
  %Sandbox.WriteResult{error: nil} = Sandbox.write(sandbox, "/statuses.txt", "refunded\npending\nrefunded\n")

  {:ok, agent} =
    BeamWeaver.Agent.build(
      model: "openai:gpt-5.4-mini",
      model_opts: [max_tokens: 512, timeout: 60_000],
      system_prompt: "Run the requested command with execute, then report its output. Do not modify the input file.",
      filesystem: BeamWeaver.Filesystem.Sandbox.new(sandbox: sandbox),
      recursion_limit: 20
    )

  {:ok, result} =
    BeamWeaver.Agent.invoke(agent, %{messages: ["Run grep -c refunded statuses.txt and report the count."]})

  command_result = Enum.find(result.messages, &(&1.role == :tool and &1.name == "execute"))
  0 = command_result.metadata.exit_code
  true = BeamWeaver.Core.Message.text(command_result) =~ "2"
after
  :ok = Sandbox.Docker.stop(sandbox)
end
```

The model runs outside the container; only workspace operations run inside it.
Provider credentials are not needed in the container. Initial image download
requires host Docker access; the running container defaults to no network.

## Docker sandbox

`Docker.new/1` describes a container; `start!/1` returns the started value to
use for operations. Unstarted containers return `container_not_started` rather
than launching implicitly. `container:` can reference an existing container
your application owns.

Defaults include one CPU, 1 GiB memory, 256 processes, no network and a
`/workspace` working directory. Options control image/runtime, mounts, labels,
CPU/memory/process limits, network, read-only root, tmpfs, dropped capabilities
and security options. Host mount paths must be absolute.

Plain Docker shares the host kernel. Choose the runtime and mounted data for
your workload; a configured hardened runtime can provide a different boundary.
File-tool permissions do not constrain arbitrary commands inside it.

## Local sandbox

`Sandbox.local/1` maps virtual paths into `root:` and executes commands with
`sh` on the host. It is useful for trusted development tasks. A root directory
is not isolation from other host files accessible to that user.

Commands receive baseline environment variables plus explicit `env:` values.
`inherit_env: true` exposes the whole application environment, potentially
including credentials. Prefer explicit inputs. Local output defaults to a
512,000-byte limit; Docker defaults to 100,000 bytes. Truncated output keeps
its beginning and end and marks the omission.

## Use a sandbox directly

`Sandbox` exposes read/write/edit, list/glob/grep, batch upload/download and
execute operations. File operations return result structs with error fields;
batch operations report each file separately. Paths are virtual absolute
paths, while commands start in the sandbox working directory.

Uploads and writes replace existing files. Download artifacts you need before
cleanup. Successful construction or an empty result object is not evidence
that a command completed; inspect error, exit code and expected artifacts.

This complete local example creates a file, counts matching lines, and removes its workspace:

```elixir
alias BeamWeaver.Sandbox
root = Path.join(System.tmp_dir!(), "beam-weaver-local-#{System.unique_integer([:positive])}")

try do
  local = Sandbox.local(root: root)
  %Sandbox.WriteResult{error: nil} = Sandbox.write(local, "/orders.csv", "refunded\npending\nrefunded\n")
  result = Sandbox.execute(local, "grep -c refunded orders.csv", timeout: 5)
  {0, "2\n", nil} = {result.exit_code, result.output, result.error}
after
  File.rm_rf!(root)
end
```

## Exit codes

The execute tool can return a successful tool message even when the command
exits nonzero: the tool delivered the command result successfully. Inspect
`metadata.exit_code`, not only tool status. Timeouts or backend failures may
produce an error without a usable command exit code. Offloading long output
keeps its metadata.

## Command timeouts

Sandbox execute timeouts are **seconds**, 1–3,600, default 120. Agent/node
budgets and the policy-checked Shell tool use **milliseconds**.
Timed-out commands and their process groups are terminated, then killed if
needed. A direct timeout result reports exit code 124 and error `timeout`.
Stopping a command does not undo file or external side effects already made.

The shell tool uses milliseconds for its policy timeout:

```elixir
slow = BeamWeaver.Tools.Shell.new(policy: [allow: ["sleep"], timeout: 50])
BeamWeaver.Core.Tool.invoke(slow, %{"command" => "sleep 5"})
#=> {:error, %BeamWeaver.Core.Error{type: :shell_timeout}}
```

## Shell tool and policies

`BeamWeaver.Tools.Shell` requires a `ShellPolicy`. Deny rules win. Command
prefix rules and regex rules normally cover one command, not shell chaining:

```elixir
policy = BeamWeaver.ShellPolicy.new!(allow: ["grep", "wc -l"], deny: [~r/--recursive/])
true = BeamWeaver.ShellPolicy.allowed?(policy, "grep -c refunded statuses.txt")
false = BeamWeaver.ShellPolicy.allowed?(policy, "grep -c x statuses.txt; rm statuses.txt")
false = BeamWeaver.ShellPolicy.allowed?(policy, "grep --recursive x /")
```

Compound commands need `allow_compound: true` and a suitably anchored rule.
Options include cwd, explicit environment, timeout, output size, redactions
and an executor for one-shot commands in another environment.

### Commands that run other commands

The policy examines supported wrappers and nested commands. Execution-mode
wrappers such as `env`, `timeout` or `sh -c` do not bypass checking the wrapped
command. User/host/fan-out wrappers such as sudo, ssh or xargs need suitable
rules for both wrapper behavior and invoked command. Deny checks inspect
nested forms too.

The policy recognizes supported command wrappers; these strings are checked, not executed:

```elixir
policy = BeamWeaver.ShellPolicy.new!(allow: ["pytest", "make"], deny: ["rm "])

cmds = [
  "timeout 30 pytest -q",
  "env FOO=1 make",
  "DEBUG=* make",
  "sh -c 'make'",
  "sh -c 'rm -rf .'",
  "timeout 5 rm -rf ."
]

Enum.map(cmds, &BeamWeaver.ShellPolicy.allowed?(policy, &1))
#=> [true, true, true, true, false, false]
```

### Code the policy can't read

Inline interpreter code, scripts, dynamically formed commands and shell
constructs whose behavior cannot be inspected are rejected unless explicitly
allowed by the relevant prefix or `allow_opaque:`. Such permission also means
the policy cannot inspect everything that code later does. A permitted test
suite or Makefile can itself run commands. Use an isolated execution boundary
for untrusted code rather than relying on string filtering.

`Agent.Middleware.ShellTool` provides a persistent host shell session instead
of one-shot execution. It requires a policy and checks startup commands too.
Sessions can retain cwd/environment across calls and a review pause; idle
sessions expire (default 15 minutes). A custom one-shot executor is not
supported for this persistent session form.

Check the whole command before execution:

```elixir
policy = BeamWeaver.ShellPolicy.new!(allow: ["grep", "wc -l"], deny: [~r/--recursive/])
commands = ["grep -c refunded orders.csv", "grep -c x a; rm a", "wc orders.csv", "grep --recursive x /"]

Enum.map(commands, &BeamWeaver.ShellPolicy.allowed?(policy, &1))
#=> [true, false, false, false]
```

Compound commands require explicit opt-in and an appropriately narrow rule:

```elixir
build = BeamWeaver.ShellPolicy.new!(allow: [~r/^mix compile && mix test$/], allow_compound: true)
Enum.map(["mix compile && mix test", "mix compile && rm -rf ~"], &BeamWeaver.ShellPolicy.allowed?(build, &1))
#=> [true, false]
```

An allowlist can restrict a script name, but cannot inspect what the allowed script does:

```elixir
tools = BeamWeaver.ShellPolicy.new!(allow: ["python3 report.py", "python3 -c"])
Enum.map(["python3 report.py", "python3 -c 'print(1)'", "python3 evil.py"], &BeamWeaver.ShellPolicy.allowed?(tools, &1))
#=> [true, true, false]
```

## Interpreters

An interpreter adapter gives stateful evaluation a narrower API than a shell.
This complete local adapter demonstrates state and snapshot restoration:

```elixir
defmodule MyApp.TallyInterpreter do
  @behaviour BeamWeaver.Sandbox.Interpreter
  @impl true
  def open(_opts), do: {:ok, 0}
  @impl true
  def eval(total, "add " <> number, _opts) do
    next = total + String.to_integer(number)
    {:ok, next, next}
  end

  def eval(total, "total", _opts), do: {:ok, total, total}
  @impl true
  def snapshot(total, _opts), do: {:ok, total}
  @impl true
  def restore(total, _opts), do: {:ok, total}
end

alias BeamWeaver.Sandbox.Interpreter.Session
{:ok, session} = Session.start(adapter: MyApp.TallyInterpreter, timeout: 1_000)
{:ok, restored} = Session.start(adapter: MyApp.TallyInterpreter)

try do
  {:ok, 25} = Session.eval(session, "add 25")
  {:ok, snapshot} = Session.snapshot(session)
  {:ok, 65} = Session.eval(session, "add 40")
  :ok = Session.restore(restored, snapshot)
  {:ok, 25} = Session.eval(restored, "total")
after
  Session.close(session)
  Session.close(restored)
end
```

Timeouts and raised failures preserve session state. An adapter can explicitly
return a changed state alongside an error; that state is retained. Snapshots must be plain
bounded data (default maximum 1,000,000 bytes). An adapter defines what code
means and what isolation exists; the session process alone is not a language
security boundary.

This complete interpreter keeps an integer tally and supports snapshot/restore:

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

## Custom sandbox adapters

Implement the `BeamWeaver.Sandbox` behavior on a struct. Return operation
results consistently and provide canonical-path resolution when storage has
symlinks. `Filesystem.Sandbox` then adapts it for agent tools. Wrappers must
forward link resolution so permission checks see actual targets.

A sandbox wrapper can attach an identifier to command results:

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

## Provider registry

`Sandbox.Registry` selects configured providers implementing `Sandbox.Provider`.
Provider capabilities describe supported lifecycle inputs such as sandbox IDs,
snapshots, mounts and working directories. Unsupported lifecycle options fail
rather than silently disappear. The registry builds adapters; it does not
supply an undocumented hosted service.

Register and build that wrapper with an explicit tenant workspace. Derive the sandbox ID from trusted application data:

```elixir
alias BeamWeaver.Sandbox

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
  config: %{base_dir: Path.join(System.tmp_dir!(), "beam-weaver-tenants-#{System.unique_integer([:positive])}")},
  capabilities: %{sandbox_id: true}
}

{:ok, registry} = Registry.new(providers: [tenants])
{:ok, sandbox} = Registry.build(registry, :tenants, sandbox_id: "sbx_ada")

try do
  result = Sandbox.execute(sandbox, "printf ok")
  {0, "ok", "sbx_ada"} = {result.exit_code, result.output, result.metadata.sandbox_id}
after
  File.rm_rf!(tenants.config.base_dir)
end
```

## Lifecycle and cleanup

A container's starting process owns its default automatic removal. Start
thread/customer workspaces in a suitable long-lived owner, not inside an
agent declaration evaluated per call. Stop owned resources explicitly.
After a VM crash, `stop_owned/2` checks labels before cleaning an orphan.
`remove: false` changes automatic cleanup, not responsibility for removal.

Docker `start_exec`, `read_exec` and `stop_exec` support longer commands whose
output must outlive the caller. Store the required identifiers and reconcile
completion before restarting work. Local cleanup means removing only the
application-owned root after artifacts are collected.
