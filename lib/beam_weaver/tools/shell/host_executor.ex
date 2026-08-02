defmodule BeamWeaver.Tools.Shell.HostExecutor do
  @moduledoc """
  Host shell executor for explicitly allowed commands.
  """

  @behaviour BeamWeaver.Tools.Shell.Executor

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.ID
  alias BeamWeaver.ShellPolicy
  alias BeamWeaver.Tools.Shell.CommandRunner
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
    {stderr, after_run, scratch} = prepare_stderr(policy)
    metadata = command_metadata(:host, command, policy.timeout, opts)

    case CommandRunner.run(command,
           shell: shell(),
           cd: policy.cwd,
           env: env(policy),
           stderr: stderr,
           timeout: policy.timeout
         ) do
      {:ok, output, status} ->
        stderr = after_run.()

        {:ok,
         command
         |> base_result(status, output, policy, Map.put(metadata, :exit_code, status))
         |> maybe_put_stderr(stderr, policy)}

      :timeout ->
        cleanup_scratch(scratch)

        {:error,
         Error.new(:shell_timeout, "shell command timed out", %{
           command: command,
           metadata: Map.merge(metadata, %{kill_attempted: true, error: "timeout"})
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
