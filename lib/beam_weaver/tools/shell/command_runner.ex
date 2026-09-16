defmodule BeamWeaver.Tools.Shell.CommandRunner do
  @moduledoc false

  @spec run(String.t(), keyword()) ::
          {:ok, binary(), non_neg_integer()} | :timeout | {:error, term()}
  def run(script, opts) when is_binary(script) do
    marker = "__beam_weaver_shell_ready_#{System.unique_integer([:positive])}__"
    command = instrument(script, marker, Keyword.get(opts, :stderr, :merge))
    deadline = deadline(Keyword.get(opts, :timeout, :infinity))

    port =
      Port.open(
        {:spawn_executable, opts |> Keyword.fetch!(:shell) |> String.to_charlist()},
        port_options(command, opts)
      )

    Process.unlink(port)

    case await_ready(port, marker, "", deadline) do
      {:ready, output} -> collect_output(port, [output], deadline)
      {:exit, output, status} -> {:ok, output, status}
      {:error, reason} -> {:error, reason}
      {:timeout, buffered} -> timeout_after_readiness(port, marker, buffered)
    end
  rescue
    exception -> {:error, exception}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp timeout_after_readiness(port, marker, buffered) do
    case await_ready(port, marker, buffered, :infinity) do
      {:ready, _output} -> close_port(port)
      {:exit, _output, _status} -> :ok
      {:error, _reason} -> :ok
    end

    :timeout
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

  defp collect_output(port, chunks, deadline) do
    case receive_port(port, remaining(deadline)) do
      {:data, data} ->
        collect_output(port, [data | chunks], deadline)

      {:exit, status} ->
        {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary(), status}

      {:error, reason} ->
        {:error, reason}

      :timeout ->
        close_port(port)
        :timeout
    end
  end

  defp receive_port(port, :infinity) do
    receive do
      {^port, {:data, data}} -> {:data, data}
      {^port, {:exit_status, status}} -> {:exit, status}
      {:EXIT, ^port, reason} -> {:error, reason}
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
    |> maybe_put_env(Keyword.get(opts, :env, []))
  end

  defp maybe_put_stderr_to_stdout(options, :merge), do: [:stderr_to_stdout | options]
  defp maybe_put_stderr_to_stdout(options, _stderr), do: options

  defp maybe_put_cd(options, nil), do: options
  defp maybe_put_cd(options, cwd), do: [{:cd, String.to_charlist(cwd)} | options]

  defp maybe_put_env(options, []), do: options

  defp maybe_put_env(options, env) do
    env =
      Enum.map(env, fn {key, value} ->
        {key |> to_string() |> String.to_charlist(), value |> to_string() |> String.to_charlist()}
      end)

    [{:env, env} | options]
  end

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
end
