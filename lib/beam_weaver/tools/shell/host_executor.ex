defmodule BeamWeaver.Tools.Shell.HostExecutor do
  @moduledoc """
  Host shell executor for explicitly allowed commands.
  """

  @behaviour BeamWeaver.Tools.Shell.Executor

  alias BeamWeaver.Core.Error
  alias BeamWeaver.ShellPolicy
  alias BeamWeaver.Tools.Shell.CommandRunner

  @impl true
  def run(command, %ShellPolicy{} = policy, opts \\ []) do
    with :ok <- ShellPolicy.check(policy, command) do
      run_allowed(command, policy, opts)
    end
  end

  defp run_allowed(command, policy, opts) do
    {stderr, after_run, scratch} = prepare_stderr(policy)
    metadata = CommandRunner.metadata(:host, command, policy.timeout, opts)

    case CommandRunner.run(command,
           shell: CommandRunner.shell(),
           cd: policy.cwd,
           env: policy.env,
           inherit_env: policy.inherit_env,
           stderr: stderr,
           timeout: policy.timeout
         ) do
      {:ok, output, status} ->
        stderr = after_run.()

        {:ok,
         command
         |> CommandRunner.result(status, output, policy, Map.put(metadata, :exit_code, status))
         |> CommandRunner.put_stderr(stderr, policy)}

      {:timeout, kill_attempted?} ->
        cleanup_scratch(scratch)

        {:error,
         Error.new(:shell_timeout, "shell command timed out", %{
           command: command,
           metadata: Map.merge(metadata, %{kill_attempted: kill_attempted?, error: "timeout"})
         })}

      {:error, reason} ->
        cleanup_scratch(scratch)

        {:error,
         Error.new(:shell_execution_error, "shell command failed", %{
           command: command,
           reason: inspect(reason),
           metadata: Map.put(metadata, :reason, inspect(reason))
         })}
    end
  end

  defp cleanup_scratch(nil), do: :ok
  defp cleanup_scratch(path), do: File.rm_rf(path)

  defp prepare_stderr(%ShellPolicy{stderr: :separate}) do
    scratch =
      Path.join(
        System.tmp_dir!(),
        "beam_weaver_shell_scratch_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(scratch)
    path = Path.join(scratch, "stderr")

    {{:file, path},
     fn ->
       stderr =
         case File.read(path) do
           {:ok, data} -> data
           {:error, _reason} -> ""
         end

       File.rm_rf(scratch)
       stderr
     end, scratch}
  end

  defp prepare_stderr(%ShellPolicy{stderr: :discard}), do: {:discard, fn -> nil end, nil}

  defp prepare_stderr(_policy), do: {:merge, fn -> nil end, nil}
end
