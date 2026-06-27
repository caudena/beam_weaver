defmodule BeamWeaver.Tools.Shell.HostExecutor do
  @moduledoc """
  Host shell executor for explicitly allowed commands.
  """

  @behaviour BeamWeaver.Tools.Shell.Executor

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.ID
  alias BeamWeaver.ShellPolicy
  alias BeamWeaver.Tracing.Redactor

  @impl true
  def run(command, %ShellPolicy{} = policy, opts \\ []) do
    if ShellPolicy.allowed?(policy, command) do
      run_allowed(command, policy, opts)
    else
      {:error, Error.new(:shell_command_rejected, "shell command is not allowed", %{command: command})}
    end
  end

  defp run_allowed(command, policy, opts) do
    {shell_command, after_run, scratch} = prepare_command(command, policy)
    metadata = command_metadata(:host, command, policy.timeout, opts)

    task =
      Task.async(fn ->
        {output, status} = System.cmd(shell(), ["-c", shell_command], system_opts(policy))
        {output, status, after_run.()}
      end)

    case Task.yield(task, yield_timeout(policy.timeout)) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, status, stderr}} ->
        {:ok,
         command
         |> base_result(status, output, policy, Map.put(metadata, :exit_code, status))
         |> maybe_put_stderr(stderr, policy)}

      nil ->
        cleanup_scratch(scratch)

        {:error,
         Error.new(:shell_timeout, "shell command timed out", %{
           command: command,
           metadata: Map.merge(metadata, %{kill_attempted: true, error: "timeout"})
         })}

      {:exit, reason} ->
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

  defp yield_timeout(nil), do: :infinity
  defp yield_timeout(:infinity), do: :infinity
  defp yield_timeout(timeout), do: timeout

  defp system_opts(policy) do
    []
    |> maybe_put_cd(policy.cwd)
    |> Keyword.put(:stderr_to_stdout, policy.stderr == :merge)
    |> Keyword.put(:env, env(policy))
  end

  defp prepare_command(command, %ShellPolicy{stderr: :separate}) do
    scratch =
      Path.join(
        System.tmp_dir!(),
        "beam_weaver_shell_scratch_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(scratch)
    path = Path.join(scratch, "stderr")
    shell_command = "(" <> command <> ") 2> " <> shell_quote(path)

    {shell_command,
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

  defp prepare_command(command, %ShellPolicy{stderr: :discard}) do
    {"(" <> command <> ") 2> /dev/null", fn -> nil end, nil}
  end

  defp prepare_command(command, _policy), do: {command, fn -> nil end, nil}

  defp base_result(command, status, output, policy, metadata) do
    %{
      command: command,
      status: status,
      output: format_output(output, policy),
      metadata: Redactor.redact(metadata)
    }
  end

  defp maybe_put_stderr(result, nil, _policy), do: result

  defp maybe_put_stderr(result, stderr, policy),
    do: Map.put(result, :stderr, format_output(stderr, policy))

  defp maybe_put_cd(opts, nil), do: opts
  defp maybe_put_cd(opts, cwd), do: Keyword.put(opts, :cd, cwd)

  defp env(policy) do
    policy.env
    |> Enum.filter(fn {key, _value} ->
      policy.env_allowlist == [] or to_string(key) in policy.env_allowlist
    end)
    |> Enum.map(fn {key, value} -> {to_string(key), to_string(value)} end)
  end

  defp format_output(output, policy) do
    output
    |> redact(policy.redactions)
    |> truncate(policy.max_output_bytes, policy.truncation_indicator)
    |> maybe_empty_output(policy.empty_output)
  end

  defp redact(output, redactions) do
    Enum.reduce(redactions, output || "", fn {regex, replacement}, acc ->
      Regex.replace(regex, acc, replacement)
    end)
  end

  defp maybe_empty_output("", replacement) when is_binary(replacement), do: replacement
  defp maybe_empty_output(output, _replacement), do: output

  defp truncate(output, max_bytes, _indicator) when byte_size(output) <= max_bytes, do: output
  defp truncate(output, max_bytes, nil), do: binary_part(output, 0, max_bytes)

  defp truncate(output, max_bytes, true) do
    binary_part(output, 0, max_bytes) <> "\n[Output truncated to #{max_bytes} bytes]"
  end

  defp truncate(output, max_bytes, indicator) when is_binary(indicator) do
    binary_part(output, 0, max_bytes) <> indicator
  end

  defp shell_quote(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp shell, do: System.find_executable("sh") || "/bin/sh"

  defp command_metadata(backend, command, timeout, opts) do
    %{
      backend: backend,
      command: command,
      command_id: Keyword.get_lazy(opts, :command_id, fn -> ID.uuidv7() end),
      timeout_ms: timeout
    }
    |> Redactor.redact()
  end
end
