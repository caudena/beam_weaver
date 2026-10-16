defmodule BeamWeaver.Tools.Shell.CommandRunner do
  @moduledoc false

  alias BeamWeaver.Core.ID
  alias BeamWeaver.Tracing.Redactor

  # How long a timed-out command gets to exit after SIGTERM before everything
  # left in its process group is killed, and how long to then wait for the
  # killed shell's exit status.
  @term_grace_ms 1_000
  @kill_wait_ms 1_000

  # The variables a command keeps from the application's environment, besides
  # every `LC_*` locale variable, unless the caller passes `inherit_env: true`.
  # Everything else, such as provider API keys, stays out of the command.
  @base_env ~w(PATH HOME LANG TMPDIR USER SHELL)

  # Runs `script` with `sh -c`. Options: `:shell` (required), `:cd`, `:env`
  # (variables to set; a `nil` value unsets one), `:inherit_env` (default
  # `false`: the command sees only the base variables above plus `:env`;
  # `true`: the application's whole environment plus `:env`), `:stderr`
  # (`:merge`, `:discard` or `{:file, path}`), `:timeout` in milliseconds,
  # `:into`, a `Collectable` for the output (a binary by default), and
  # `:term_grace`, the milliseconds a timed-out command gets between SIGTERM
  # and SIGKILL.
  #
  # A command that outlives its timeout is stopped together with every process
  # it started; the result is then `{:timeout, kill_attempted?}`, where
  # `kill_attempted?` is false only if the command had already exited. A
  # guardian process stops the command the same way if the caller itself dies
  # before `run/2` returns (a `Task.shutdown/2` of a tool task, say).
  @spec run(String.t(), keyword()) ::
          {:ok, term(), non_neg_integer()} | {:timeout, boolean()} | {:error, term()}
  def run(script, opts) when is_binary(script) do
    marker = "__beam_weaver_shell_ready_#{System.unique_integer([:positive])}__"
    command = instrument(script, marker, Keyword.get(opts, :stderr, :merge))
    deadline = deadline(Keyword.get(opts, :timeout, :infinity))
    {acc, collect} = Collectable.into(Keyword.get(opts, :into, ""))

    port =
      Port.open(
        {:spawn_executable, opts |> Keyword.fetch!(:shell) |> String.to_charlist()},
        port_options(command, opts)
      )

    Process.unlink(port)
    child = %{port: port, os_pid: os_pid(port), term_grace: Keyword.get(opts, :term_grace, @term_grace_ms)}
    guardian = start_guardian(child, deadline)

    try do
      case await_ready(port, marker, "", deadline) do
        {:ready, output} ->
          collect_output(child, collect.(acc, {:cont, output}), collect, deadline)

        {:exit, output, status} ->
          {:ok, collect.(collect.(acc, {:cont, output}), :done), status}

        {:error, reason} ->
          collect.(acc, :halt)
          {:error, reason}

        {:timeout, buffered} ->
          result = timeout_after_readiness(child, marker, buffered)
          collect.(acc, :halt)
          result
      end
    after
      stand_down(guardian)
    end
  rescue
    exception -> {:error, exception}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  # The most `run/2` can take beyond its `:timeout` to stop a command with the
  # default `:term_grace`.
  @doc false
  def stop_budget, do: @term_grace_ms + @kill_wait_ms

  defp os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} -> os_pid
      nil -> nil
    end
  end

  # A separate, unlinked process that signals the command's process group if
  # the caller dies before `run/2` returns, or if the command outlives even
  # the stop budget. `run/2` stands it down on every ordinary return (timeout
  # included), so it only ever fires for a caller that never got to clean up,
  # such as one killed by `Task.shutdown(task, :brutal_kill)`.
  defp start_guardian(%{os_pid: nil}, _deadline), do: nil

  defp start_guardian(child, deadline) do
    caller = self()
    token = make_ref()
    pid = spawn(fn -> guard(caller, child, token, guardian_timeout(deadline)) end)
    {pid, token}
  end

  defp guard(caller, child, token, timeout) do
    ref = Process.monitor(caller)

    receive do
      {:beam_weaver_stand_down, ^token} -> Process.demonitor(ref, [:flush])
      {:DOWN, ^ref, :process, _pid, _reason} -> kill_group(child)
    after
      timeout -> kill_group(child)
    end
  end

  defp stand_down(nil), do: :ok
  defp stand_down({pid, token}), do: send(pid, {:beam_weaver_stand_down, token})

  defp guardian_timeout(:infinity), do: :infinity
  defp guardian_timeout(deadline), do: max(remaining(deadline), 0) + @term_grace_ms + @kill_wait_ms + 1_000

  # The guardian is the "caller died" path, so it cleans up promptly: SIGTERM,
  # a short grace, then SIGKILL, regardless of the command's own `:term_grace`.
  defp kill_group(%{os_pid: os_pid, term_grace: term_grace}) do
    signal_group(os_pid, "TERM")
    Process.sleep(guardian_grace(term_grace))
    signal_group(os_pid, "KILL")
  end

  defp guardian_grace(term_grace) when is_integer(term_grace) and term_grace >= 0,
    do: min(term_grace, @term_grace_ms)

  defp guardian_grace(_term_grace), do: @term_grace_ms

  # The deadline passed before the shell reported ready. Wait until it does:
  # signalling its process group any earlier is unreliable, and a command that
  # has already finished needs no signal at all.
  defp timeout_after_readiness(%{port: port} = child, marker, buffered) do
    case await_ready(port, marker, buffered, :infinity) do
      {:ready, _output} -> terminate(child)
      {:exit, _output, _status} -> {:timeout, false}
      {:error, _reason} -> {:timeout, false}
    end
  end

  # ERTS starts port programs in a session of their own, so the shell leads a
  # process group holding everything the command started. SIGTERM the group,
  # give it a moment to exit, then SIGKILL whatever is left (processes that
  # ignore TERM, background jobs). Draining the port afterwards keeps late
  # output and the exit status out of the caller's mailbox.
  defp terminate(%{port: port, os_pid: os_pid, term_grace: term_grace}) do
    signal_group(os_pid, "TERM")
    exited? = await_exit(port, deadline(term_grace))
    signal_group(os_pid, "KILL")
    unless exited?, do: await_exit(port, deadline(@kill_wait_ms))
    close_port(port)
    flush_port(port)
    {:timeout, true}
  end

  defp signal_group(nil, _signal), do: :ok

  defp signal_group(os_pid, signal) do
    # `kill -SIG -PGID` rather than `kill -s SIG -- -PGID`: BusyBox rejects `--`.
    System.cmd(shell(), ["-c", "kill -#{signal} -#{os_pid} 2>/dev/null"])
    :ok
  end

  defp await_exit(port, deadline) do
    receive do
      {^port, {:exit_status, _status}} -> true
      {^port, {:data, _data}} -> await_exit(port, deadline)
    after
      remaining(deadline) -> false
    end
  end

  defp flush_port(port) do
    receive do
      {^port, _message} -> flush_port(port)
    after
      0 -> :ok
    end
  end

  defp await_ready(port, marker, buffered, deadline) do
    case split_ready(buffered, marker) do
      {:ok, output} ->
        {:ready, output}

      :pending ->
        case receive_port(port, remaining(deadline)) do
          {:data, data} -> await_ready(port, marker, buffered <> data, deadline)
          {:exit, status} -> {:exit, buffered, status}
          {:error, reason} -> {:error, reason}
          :timeout -> {:timeout, buffered}
        end
    end
  end

  defp collect_output(%{port: port} = child, acc, collect, deadline) do
    case receive_port(port, remaining(deadline)) do
      {:data, data} ->
        collect_output(child, collect.(acc, {:cont, data}), collect, deadline)

      {:exit, status} ->
        {:ok, collect.(acc, :done), status}

      {:error, reason} ->
        collect.(acc, :halt)
        {:error, reason}

      :timeout ->
        result = terminate(child)
        collect.(acc, :halt)
        result
    end
  end

  defp receive_port(port, timeout) do
    receive do
      {^port, {:data, data}} -> {:data, data}
      {^port, {:exit_status, status}} -> {:exit, status}
      {:EXIT, ^port, reason} -> {:error, reason}
    after
      timeout -> :timeout
    end
  end

  defp split_ready(buffered, marker) do
    case :binary.match(buffered, marker) do
      {offset, size} ->
        prefix = binary_part(buffered, 0, offset)
        suffix_offset = offset + size
        suffix = binary_part(buffered, suffix_offset, byte_size(buffered) - suffix_offset)
        {:ok, prefix <> suffix}

      :nomatch ->
        :pending
    end
  end

  # The port is opened with `:in` only, so no stdin pipe is created and the
  # command inherits the VM's own stdin: a terminal under `iex`/`mix test`, a
  # socket or a pipe under a supervisor. Nothing ever sends EOF on that fd, so a
  # command that reads stdin (`cat`, `read`, interactive prompts) would block
  # until the timeout. Give every command EOF on stdin instead.
  defp instrument(script, marker, stderr) do
    IO.iodata_to_binary([
      "exec </dev/null\n",
      stderr_redirect(stderr),
      "printf '%s' ",
      shell_quote(marker),
      "\neval ",
      shell_quote(script)
    ])
  end

  defp stderr_redirect({:file, path}), do: ["exec 2> ", shell_quote(path), "\n"]
  defp stderr_redirect(:discard), do: "exec 2> /dev/null\n"
  defp stderr_redirect(:merge), do: []

  defp port_options(command, opts) do
    [
      :binary,
      :exit_status,
      :hide,
      :in,
      :use_stdio,
      {:args, [~c"-c", String.to_charlist(command)]}
    ]
    |> maybe_put_stderr_to_stdout(Keyword.get(opts, :stderr, :merge))
    |> maybe_put_cd(Keyword.get(opts, :cd))
    |> maybe_put_env(command_env(Keyword.get(opts, :env, []), Keyword.get(opts, :inherit_env, false)))
  end

  defp maybe_put_stderr_to_stdout(options, :merge), do: [:stderr_to_stdout | options]
  defp maybe_put_stderr_to_stdout(options, _stderr), do: options

  defp maybe_put_cd(options, nil), do: options
  defp maybe_put_cd(options, cwd), do: [{:cd, String.to_charlist(cwd)} | options]

  defp maybe_put_env(options, []), do: options

  defp maybe_put_env(options, env) do
    env = Enum.map(env, fn {key, value} -> {String.to_charlist(key), env_value(value)} end)
    [{:env, env} | options]
  end

  # A port's `:env` only changes the environment the command inherits from the
  # VM, so a minimal environment unsets every inherited variable outside the
  # base set (and not set explicitly) before applying `env`.
  defp command_env(env, inherit_env?) do
    env = Map.new(env, fn {key, value} -> {to_string(key), value} end)

    unset =
      if inherit_env? do
        []
      else
        for {name, _value} <- System.get_env(),
            not base_env?(name) and not Map.has_key?(env, name),
            do: {name, nil}
      end

    unset ++ Enum.to_list(env)
  end

  defp base_env?("LC_" <> _locale), do: true
  defp base_env?(name), do: name in @base_env

  defp env_value(nil), do: false

  # The value's bytes, passed through unchanged. `String.to_charlist/1` would
  # raise on a non-UTF-8 value (a legacy exported variable carried over in a
  # session) and would turn a UTF-8 value into code points the port re-encodes
  # as Latin-1; `:binary.bin_to_list/1` keeps the exact bytes and never raises.
  defp env_value(value), do: value |> to_string() |> :binary.bin_to_list()

  defp deadline(nil), do: :infinity
  defp deadline(:infinity), do: :infinity
  defp deadline(timeout), do: System.monotonic_time(:millisecond) + timeout

  defp remaining(:infinity), do: :infinity
  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  defp close_port(port) do
    if Port.info(port), do: Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp shell_quote(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  @doc false
  def shell, do: System.find_executable("sh") || "/bin/sh"

  # A readable message for the `{:error, reason}` that `run/2` returns.
  @doc false
  def error_message(%{__exception__: true} = exception), do: Exception.message(exception)
  def error_message(reason), do: inspect(reason)

  @doc false
  def metadata(backend, command, timeout, opts) do
    Redactor.redact(%{
      backend: backend,
      command: command,
      command_id: Keyword.get_lazy(opts, :command_id, fn -> ID.uuidv7() end),
      timeout_ms: timeout
    })
  end

  # The tool result for one command, with output redacted and truncated per policy.
  @doc false
  def result(command, status, output, policy, metadata) do
    %{
      command: command,
      status: status,
      output: format_output(output, policy),
      metadata: Redactor.redact(metadata)
    }
  end

  @doc false
  def put_stderr(result, nil, _policy), do: result
  def put_stderr(result, stderr, policy), do: Map.put(result, :stderr, format_output(stderr, policy))

  defp format_output(output, policy) do
    output
    |> redact(policy.redactions)
    |> truncate(policy.max_output_bytes, policy.truncation_indicator)
    |> maybe_empty_output(policy.empty_output)
  end

  defp redact(output, redactions) do
    Enum.reduce(redactions, output, fn {regex, replacement}, acc ->
      Regex.replace(regex, acc, replacement)
    end)
  end

  defp maybe_empty_output("", replacement) when is_binary(replacement), do: replacement
  defp maybe_empty_output(output, _replacement), do: output

  defp truncate(output, max_bytes, _indicator) when byte_size(output) <= max_bytes, do: output
  defp truncate(output, max_bytes, nil), do: binary_part(output, 0, max_bytes)

  defp truncate(output, max_bytes, true),
    do: binary_part(output, 0, max_bytes) <> "\n[Output truncated to #{max_bytes} bytes]"

  defp truncate(output, max_bytes, indicator) when is_binary(indicator),
    do: binary_part(output, 0, max_bytes) <> indicator
end
