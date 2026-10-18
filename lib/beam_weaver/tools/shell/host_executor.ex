defmodule BeamWeaver.Tools.Shell.HostExecutor do
  @moduledoc """
  Host shell executor for explicitly allowed commands.
  """

  @behaviour BeamWeaver.Tools.Shell.Executor

  alias BeamWeaver.Sandbox.CommandRunner
  alias BeamWeaver.ShellPolicy

  @impl true
  def run(command, %ShellPolicy{} = policy, opts \\ []) do
    with :ok <- ShellPolicy.check(policy, command) do
      run_allowed(command, policy, opts)
    end
  end

  defp run_allowed(command, policy, opts) do
    metadata = CommandRunner.metadata(:host, command, policy.timeout, opts)
    scratch = if policy.stderr == :separate, do: CommandRunner.scratch_dir()
    stderr_path = scratch && Path.join(scratch, "stderr")

    result =
      CommandRunner.run(command,
        shell: CommandRunner.shell(),
        cd: policy.cwd,
        env: policy.env,
        inherit_env: policy.inherit_env,
        stderr: CommandRunner.stderr_option(stderr_path, policy),
        timeout: policy.timeout
      )

    stderr = CommandRunner.read_stderr(stderr_path, policy)
    if scratch, do: File.rm_rf(scratch)

    case result do
      {:ok, output, status} ->
        {:ok,
         command
         |> CommandRunner.result(status, output, policy, Map.put(metadata, :exit_code, status))
         |> CommandRunner.put_stderr(stderr, policy)}

      failure ->
        {:error, CommandRunner.failure(command, failure, metadata)}
    end
  end
end
