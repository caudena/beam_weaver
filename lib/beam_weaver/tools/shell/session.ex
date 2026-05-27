defmodule BeamWeaver.Tools.Shell.Session do
  @moduledoc """
  GenServer-backed shell session for agent shell middleware.

  The session keeps the public boundary native to BeamWeaver: callers interact
  with a supervised process and an explicit `ShellPolicy`. The implementation
  preserves practical shell state between commands by carrying forward the
  working directory and exported environment after each successful command.
  """

  use GenServer

  alias BeamWeaver.Core.Error
  alias BeamWeaver.ShellPolicy

  defstruct [
    :policy,
    :initial_cwd,
    :cwd,
    :temp_root,
    startup_commands: [],
    shutdown_commands: [],
    env: %{}
  ]

  @type t :: pid()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @spec start(keyword()) :: GenServer.on_start()
  def start(opts) do
    GenServer.start(__MODULE__, opts)
  end

  @spec execute(t(), String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def execute(pid, command, opts \\ []) when is_pid(pid) do
    GenServer.call(pid, {:execute, command, opts}, call_timeout(pid, opts))
  end

  @spec restart(t(), keyword()) :: :ok | {:error, Error.t()}
  def restart(pid, opts \\ []) when is_pid(pid) do
    GenServer.call(pid, {:restart, opts}, call_timeout(pid, opts))
  end

  @spec shutdown(t(), keyword()) :: :ok
  def shutdown(pid, opts \\ []) when is_pid(pid) do
    GenServer.call(pid, {:shutdown, opts}, call_timeout(pid, opts))
  catch
    :exit, _reason -> :ok
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    with {:ok, policy} <- ShellPolicy.new(Keyword.fetch!(opts, :policy)),
         {:ok, state} <- build_state(policy, opts),
         {:ok, state} <- run_startup_commands(state) do
      {:ok, state}
    else
      {:error, %Error{} = error} -> {:stop, error}
    end
  end

  @impl true
  def handle_call({:execute, command, opts}, _from, state) do
    case run_command(state, command, opts) do
      {:ok, result, state} -> {:reply, {:ok, result}, state}
      {:error, %Error{} = error, state} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:restart, _opts}, _from, state) do
    state = %{state | cwd: state.initial_cwd, env: policy_env(state.policy)}

    case run_startup_commands(state) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, %Error{} = error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call({:shutdown, _opts}, _from, state) do
    state = run_shutdown_commands(state)
    cleanup_temp_root(state)
    {:stop, :normal, :ok, state}
  end

  def handle_call(:policy_timeout, _from, state) do
    {:reply, state.policy.timeout, state}
  end

  @impl true
  def handle_info({:EXIT, _pid, :normal}, state), do: {:noreply, state}

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    cleanup_temp_root(state)
    :ok
  end

  defp build_state(policy, opts) do
    workspace = Keyword.get(opts, :workspace_root) || Keyword.get(opts, :workspace)

    with {:ok, cwd, temp_root} <- workspace_root(workspace, policy) do
      {:ok,
       %__MODULE__{
         policy: policy,
         initial_cwd: cwd,
         cwd: cwd,
         temp_root: temp_root,
         env: policy_env(policy),
         startup_commands: normalize_commands(Keyword.get(opts, :startup_commands, [])),
         shutdown_commands: normalize_commands(Keyword.get(opts, :shutdown_commands, []))
       }}
    end
  end

  defp workspace_root(nil, %ShellPolicy{cwd: cwd}) when is_binary(cwd) do
    cwd = Path.expand(cwd)
    File.mkdir_p!(cwd)
    {:ok, cwd, nil}
  end

  defp workspace_root(nil, _policy) do
    root =
      Path.join(
        System.tmp_dir!(),
        "beam_weaver_shell_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    {:ok, root, root}
  end

  defp workspace_root(workspace, _policy) do
    root = workspace |> to_string() |> Path.expand()
    File.mkdir_p!(root)
    {:ok, root, nil}
  rescue
    exception ->
      {:error,
       Error.new(:shell_session_start_failed, "shell workspace could not be created", %{
         reason: Exception.message(exception)
       })}
  end

  defp normalize_commands(nil), do: []
  defp normalize_commands(command) when is_binary(command), do: [command]
  defp normalize_commands(commands) when is_list(commands), do: Enum.map(commands, &to_string/1)

  defp run_startup_commands(%__MODULE__{startup_commands: []} = state), do: {:ok, state}

  defp run_startup_commands(%__MODULE__{} = state) do
    Enum.reduce_while(state.startup_commands, {:ok, state}, fn command, {:ok, state} ->
      case run_command(state, command, timeout: state.policy.timeout) do
        {:ok, %{status: status}, state} when status in [0, nil] ->
          {:cont, {:ok, state}}

        {:ok, result, _state} ->
          {:halt,
           {:error,
            Error.new(:shell_startup_failed, "shell startup command failed", %{
              command: command,
              status: result.status
            })}}

        {:error, %Error{} = error, _state} ->
          {:halt, {:error, error}}
      end
    end)
  end

  defp run_shutdown_commands(%__MODULE__{shutdown_commands: []} = state), do: state

  defp run_shutdown_commands(%__MODULE__{} = state) do
    Enum.reduce(state.shutdown_commands, state, fn command, state ->
      case run_command(state, command, timeout: state.policy.timeout) do
        {:ok, _result, state} -> state
        {:error, _error, state} -> state
      end
    end)
  end

  defp run_command(state, command, _opts) when not is_binary(command) do
    {:error, Error.new(:invalid_shell_command, "shell tool expects a command string"), state}
  end

  defp run_command(state, command, opts) do
    cond do
      String.trim(command) == "" ->
        {:error, Error.new(:invalid_shell_command, "shell command cannot be empty"), state}

      not ShellPolicy.allowed?(state.policy, command) ->
        {:error, Error.new(:shell_command_rejected, "shell command is not allowed", %{command: command}), state}

      true ->
        run_allowed(state, command, opts)
    end
  end

  defp run_allowed(state, command, opts) do
    timeout = Keyword.get(opts, :timeout, state.policy.timeout)

    task =
      Task.async(fn ->
        metadata = temp_path("metadata")
        env_path = temp_path("env")
        stderr_path = temp_path("stderr")
        script = session_script(command, metadata, env_path)
        script = redirect_stderr(script, stderr_path, state.policy)

        {output, status} =
          System.cmd(shell(), ["-c", script],
            cd: state.cwd,
            env: env_list(state.env),
            stderr_to_stdout: state.policy.stderr == :merge
          )

        metadata = read_metadata(metadata)
        env = read_env(env_path, state.env)
        stderr = read_stderr(stderr_path, state.policy)

        cleanup_paths([metadata_path(metadata), env_path, stderr_path])

        {output, status, metadata, env, stderr}
      end)

    case Task.yield(task, yield_timeout(timeout)) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, status, metadata, env, stderr}} ->
        status = Map.get(metadata, :status, status)

        state =
          state
          |> maybe_update_cwd(Map.get(metadata, :cwd))
          |> Map.put(:env, env)

        {:ok,
         command
         |> base_result(status, output, state.policy)
         |> maybe_put_stderr(stderr, state.policy), state}

      nil ->
        {:error, Error.new(:shell_timeout, "shell command timed out", %{command: command}), state}

      {:exit, reason} ->
        {:error,
         Error.new(:shell_execution_error, "shell command failed", %{
           command: command,
           reason: inspect(reason)
         }), state}
    end
  end

  defp session_script(command, metadata, env_path) do
    [
      command,
      "\n__beam_weaver_status=$?\n",
      "printf '%s\\n' \"$__beam_weaver_status\" > ",
      shell_quote(metadata),
      "\n",
      "pwd >> ",
      shell_quote(metadata),
      "\n",
      "env -0 > ",
      shell_quote(env_path),
      "\n",
      "exit $__beam_weaver_status\n"
    ]
    |> IO.iodata_to_binary()
  end

  defp redirect_stderr(script, path, %ShellPolicy{stderr: :separate}),
    do: "(" <> script <> ") 2> " <> shell_quote(path)

  defp redirect_stderr(script, _path, %ShellPolicy{stderr: :discard}),
    do: "(" <> script <> ") 2> /dev/null"

  defp redirect_stderr(script, _path, _policy), do: script

  defp base_result(command, status, output, policy) do
    %{
      command: command,
      status: status,
      output: format_output(output, policy)
    }
  end

  defp maybe_put_stderr(result, nil, _policy), do: result

  defp maybe_put_stderr(result, stderr, policy),
    do: Map.put(result, :stderr, format_output(stderr, policy))

  defp read_metadata(path) do
    case File.read(path) do
      {:ok, data} ->
        [status | rest] = String.split(data, "\n", parts: 3)
        %{status: safe_int(status), cwd: rest |> List.first() |> blank_to_nil(), path: path}

      {:error, _reason} ->
        %{path: path}
    end
  end

  defp metadata_path(%{path: path}), do: path

  defp read_env(path, fallback) do
    case File.read(path) do
      {:ok, data} ->
        data
        |> String.split(<<0>>, trim: true)
        |> Enum.reduce(%{}, fn entry, acc ->
          case String.split(entry, "=", parts: 2) do
            [key, value] -> Map.put(acc, key, value)
            _other -> acc
          end
        end)

      {:error, _reason} ->
        fallback
    end
  end

  defp read_stderr(path, %ShellPolicy{stderr: :separate}) do
    case File.read(path) do
      {:ok, data} -> data
      {:error, _reason} -> ""
    end
  end

  defp read_stderr(_path, _policy), do: nil

  defp maybe_update_cwd(state, nil), do: state

  defp maybe_update_cwd(state, cwd) do
    cwd = Path.expand(cwd, state.cwd)
    if File.dir?(cwd), do: %{state | cwd: cwd}, else: state
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

  defp cleanup_paths(paths) do
    Enum.each(paths, fn path ->
      if is_binary(path), do: File.rm(path)
    end)
  end

  defp cleanup_temp_root(%__MODULE__{temp_root: nil}), do: :ok
  defp cleanup_temp_root(%__MODULE__{temp_root: root}), do: File.rm_rf(root)

  defp policy_env(%ShellPolicy{} = policy) do
    policy.env
    |> Enum.filter(fn {key, _value} ->
      policy.env_allowlist == [] or to_string(key) in policy.env_allowlist
    end)
    |> Map.new(fn {key, value} -> {to_string(key), to_string(value)} end)
  end

  defp env_list(env), do: Enum.map(env, fn {key, value} -> {to_string(key), to_string(value)} end)

  defp call_timeout(pid, opts) do
    timeout =
      case Keyword.get(opts, :timeout) do
        nil -> GenServer.call(pid, :policy_timeout, :infinity)
        timeout -> timeout
      end

    case timeout do
      nil -> :infinity
      :infinity -> :infinity
      timeout when is_integer(timeout) -> timeout + 1_000
    end
  catch
    :exit, _reason -> :infinity
  end

  defp yield_timeout(nil), do: :infinity
  defp yield_timeout(:infinity), do: :infinity
  defp yield_timeout(timeout), do: timeout

  defp temp_path(label) do
    Path.join(
      System.tmp_dir!(),
      "beam_weaver_shell_#{label}_#{System.unique_integer([:positive])}"
    )
  end

  defp safe_int(value) do
    case Integer.parse(String.trim(to_string(value))) do
      {int, ""} -> int
      _other -> nil
    end
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: String.trim(value)

  defp shell_quote(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end

  defp shell, do: System.find_executable("sh") || "/bin/sh"
end
