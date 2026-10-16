defmodule BeamWeaver.Tools.Shell.CommandEnvTest do
  # Sets an application environment variable, so it runs alone.
  use ExUnit.Case, async: false

  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Filesystem.Executable
  alias BeamWeaver.Filesystem.LocalShell
  alias BeamWeaver.Sandbox
  alias BeamWeaver.Tools.Shell
  alias BeamWeaver.Tools.Shell.Session

  @moduletag :tmp_dir

  # Prints the secret, a configured variable and whether PATH and HOME made it.
  @probe ~S(printf '%s|%s|%s' "${BW_TEST_SECRET:-unset}" "${BW_TEST_CONFIGURED:-unset}" "${PATH:+path}${HOME:+home}")

  setup do
    System.put_env("BW_TEST_SECRET", "sk-live-123")
    on_exit(fn -> System.delete_env("BW_TEST_SECRET") end)
  end

  test "the local sandbox keeps the application's environment out of commands", %{tmp_dir: dir} do
    assert %Sandbox.ExecuteResult{exit_code: 0, output: "unset|ok|pathhome"} =
             Sandbox.execute(Sandbox.local(root: dir, env: %{"BW_TEST_CONFIGURED" => "ok"}), @probe)

    assert %Sandbox.ExecuteResult{output: "sk-live-123|unset|pathhome"} =
             Sandbox.execute(Sandbox.local(root: dir, inherit_env: true), @probe)
  end

  test "the local shell backend keeps the application's environment out of commands", %{tmp_dir: dir} do
    assert %Executable.ExecuteResult{exit_code: 0, output: "unset|ok|pathhome"} =
             Executable.execute(LocalShell.new(root: dir, env: %{"BW_TEST_CONFIGURED" => "ok"}), @probe)

    assert %Executable.ExecuteResult{output: "sk-live-123|unset|pathhome"} =
             Executable.execute(LocalShell.new(root: dir, inherit_env: true), @probe)
  end

  test "the shell tool keeps the application's environment out of commands", %{tmp_dir: dir} do
    shell = Shell.new(policy: [allow: ["printf"], cwd: dir, env: %{"BW_TEST_CONFIGURED" => "ok"}])
    assert {:ok, %{status: 0, output: "unset|ok|pathhome"}} = Tool.invoke(shell, %{"command" => @probe})

    inheriting = Shell.new(policy: [allow: ["printf"], cwd: dir, inherit_env: true])
    assert {:ok, %{output: "sk-live-123|unset|pathhome"}} = Tool.invoke(inheriting, %{"command" => @probe})
  end

  test "shell sessions keep the application's environment out and carry exports over", %{tmp_dir: dir} do
    {:ok, session} =
      Session.start(
        policy: [allow: ["printf", "export"], env: %{"BW_TEST_CONFIGURED" => "ok"}],
        workspace_root: dir
      )

    on_exit(fn -> Session.shutdown(session) end)

    assert {:ok, %{output: "unset|ok|pathhome"}} = Session.execute(session, @probe)
    assert {:ok, %{status: 0}} = Session.execute(session, "export BW_TEST_SECRET=from-session")
    assert {:ok, %{output: "from-session|ok|pathhome"}} = Session.execute(session, @probe)

    {:ok, inheriting} = Session.start(policy: [allow: ["printf"], inherit_env: true], workspace_root: dir)
    on_exit(fn -> Session.shutdown(inheriting) end)

    assert {:ok, %{output: "sk-live-123|unset|pathhome"}} = Session.execute(inheriting, @probe)
  end

  test "an explicit nil removes a variable from a command's environment", %{tmp_dir: dir} do
    assert %Sandbox.ExecuteResult{output: "unset|unset|path"} =
             Sandbox.execute(Sandbox.local(root: dir, env: %{"HOME" => nil}), @probe)
  end

  test "a session re-applies the policy's nil removals on every command", %{tmp_dir: dir} do
    {:ok, session} =
      Session.start(
        policy: [allow: ["printenv"], inherit_env: true, env: %{"BW_TEST_SECRET" => nil}],
        workspace_root: dir
      )

    on_exit(fn -> Session.shutdown(session) end)

    # The removal must survive past the first command, after which the session
    # reads the surviving environment back into its state.
    for _iteration <- 1..3 do
      assert {:ok, %{status: 1, output: ""}} = Session.execute(session, "printenv BW_TEST_SECRET")
    end
  end

  test "a session survives a non-UTF-8 exported variable", %{tmp_dir: dir} do
    # `$'...'` is only known at run time (bash and dash read it differently),
    # so the policy refuses the export unless a rule spells it out.
    {:ok, session} =
      Session.start(
        policy: [allow: [~r/\Aexport BW_LEGACY=\$'caf\\351'\z/, "printf", "true"]],
        workspace_root: dir
      )

    on_exit(fn -> Session.shutdown(session) end)

    assert {:ok, %{status: 0}} = Session.execute(session, "export BW_LEGACY=$'caf\\351'")

    # A non-UTF-8 value used to crash every later command with
    # UnicodeConversionError; the session keeps running.
    assert {:ok, %{status: 0, output: "ok"}} = Session.execute(session, "printf ok")
  end

  test "inspecting a backend or policy hides the variables it passes to commands", %{tmp_dir: dir} do
    env = %{"BW_TEST_CONFIGURED" => "sk-configured"}

    for value <- [
          Sandbox.local(root: dir, env: env),
          LocalShell.new(root: dir, env: env),
          BeamWeaver.ShellPolicy.new!(allow: ["ls"], env: env)
        ] do
      refute inspect(value) =~ "sk-configured"
    end
  end
end
