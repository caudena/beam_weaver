defmodule BeamWeaver.Tools.Shell.Session do
  @moduledoc false

  # Temporary: a session is lazily (re)started by the shell tool, never
  # restarted by its supervisor.
  use GenServer, restart: :temporary

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Sandbox.CommandRunner
  alias BeamWeaver.ShellPolicy
  alias BeamWeaver.Tools.Shell.HostExecutor

  # `env` carries the session's variables, including any the policy sets for
  # the commands (secrets among them) and whatever they export; keep it out of
  # inspected and crash-logged state.
  @derive {Inspect, except: [:env]}
  defstruct [
    :policy,
    :initial_cwd,
    :cwd,
    :temp_root,
    startup_commands: [],
    shutdown_commands: [],
    env: %{},
    idle_timeout: :infinity
  ]

  @type t :: pid()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

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
         :ok <- check_executor(policy),
         {:ok, state} <- build_state(policy, opts),
         {:ok, state} <- run_startup_commands(state) do
      {:ok, state, state.idle_timeout}
    else
      {:error, %Error{} = error} -> {:stop, error}
    end
  end

  # A session is a persistent host shell: `cd` and `export` carry over because
  # each command runs in the same host process group. A custom `:executor`
  # (one that runs commands "in a container", say) has no session semantics,
  # so a session can't honour one and refuses to start rather than silently
  # running the commands on the host. Use the one-shot `BeamWeaver.Tools.Shell`
  # for a custom executor, or a `BeamWeaver.Sandbox` for container execution.
  defp check_executor(%ShellPolicy{executor: HostExecutor}), do: :ok

  defp check_executor(%ShellPolicy{executor: executor}) do
    {:error,
     Error.new(
       :shell_session_executor_unsupported,
       "a shell session runs commands on the host and cannot use a custom executor; " <>
         "use BeamWeaver.Tools.Shell for a custom executor, or a BeamWeaver.Sandbox for container execution",
       %{executor: inspect(executor)}
     )}
  end

  @impl true
  def handle_call({:execute, command, opts}, _from, state) do
    case run_command(state, command, opts) do
      {:ok, result, state} -> {:reply, {:ok, result}, state, state.idle_timeout}
      {:error, %Error{} = error, state} -> {:reply, {:error, error}, state, state.idle_timeout}
    end
  end

  def handle_call({:restart, _opts}, _from, state) do
    state = %{state | cwd: state.initial_cwd, env: state.policy.env}

    case run_startup_commands(state) do
      {:ok, state} -> {:reply, :ok, state, state.idle_timeout}
      {:error, %Error{} = error} -> {:reply, {:error, error}, state, state.idle_timeout}
    end
  end

  def handle_call({:shutdown, _opts}, _from, state) do
    state = run_shutdown_commands(state)
    cleanup_temp_root(state)
    {:stop, :normal, :ok, state}
  end

  def handle_call(:policy_timeout, _from, state) do
    {:reply, state.policy.timeout, state, state.idle_timeout}
  end

  @impl true
  def handle_info(:timeout, state) do
    # No command for `idle_timeout` ms: stop so a run that never reaches
    # `after_agent` (a pause, an error) doesn't leave a session (and its temp
    # workspace) behind forever. A later command lazily starts a fresh one.
    state = run_shutdown_commands(state)
    cleanup_temp_root(state)
    {:stop, :normal, state}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state, state.idle_timeout}

  @impl true
  def terminate(_reason, state) do
    cleanup_temp_root(state)
    :ok
  end

  # Keep the session's variables out of the state a crash or `:sys.get_status/1`
  # would print.
  @impl true
  def format_status(%{state: %__MODULE__{} = state} = status),
    do: %{status | state: %{state | env: :redacted}}

  def format_status(status), do: status

  # The environment for one command: the session's carried-over variables with
  # the policy's removals (`env: %{"KEY" => nil}`) re-applied every time, so a
  # variable the policy drops can't come back after the first command printed
  # the surviving environment back into `state.env`.
  defp run_env(%__MODULE__{env: env, policy: policy}) do
    Enum.reduce(policy.env, env, fn
      {key, nil}, acc -> Map.put(acc, key, nil)
      {_key, _value}, acc -> acc
    end)
  end

  defp build_state(policy, opts) do
    with {:ok, cwd, temp_root} <- workspace_root(Keyword.get(opts, :workspace_root), policy) do
      {:ok,
       %__MODULE__{
         policy: policy,
         initial_cwd: cwd,
         cwd: cwd,
         temp_root: temp_root,
         env: policy.env,
         startup_commands: normalize_commands(Keyword.get(opts, :startup_commands, [])),
         shutdown_commands: normalize_commands(Keyword.get(opts, :shutdown_commands, [])),
         idle_timeout: Keyword.get(opts, :idle_timeout, :infinity)
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
    if String.trim(command) == "" do
      {:error, Error.new(:invalid_shell_command, "shell command cannot be empty"), state}
    else
      case ShellPolicy.check(state.policy, command) do
        :ok -> run_allowed(state, command, opts)
        {:error, %Error{} = error} -> {:error, error, state}
      end
    end
  end

  defp run_allowed(state, command, opts) do
    timeout = Keyword.get(opts, :timeout, state.policy.timeout)
    command_metadata = CommandRunner.metadata(:session, command, timeout, opts)
    scratch = CommandRunner.scratch_dir()
    metadata_path = Path.join(scratch, "metadata")
    env_path = Path.join(scratch, "env")
    stderr_path = Path.join(scratch, "stderr")

    result =
      CommandRunner.run(session_script(command, metadata_path, env_path),
        shell: CommandRunner.shell(),
        cd: state.cwd,
        env: run_env(state),
        inherit_env: state.policy.inherit_env,
        stderr: CommandRunner.stderr_option(stderr_path, state.policy),
        timeout: timeout
      )

    metadata = read_metadata(metadata_path)
    env = read_env(env_path, state.env)
    stderr = CommandRunner.read_stderr(stderr_path, state.policy)
    File.rm_rf(scratch)

    case result do
      {:ok, output, status} ->
        status = Map.get(metadata, :status, status)

        state =
          state
          |> maybe_update_cwd(Map.get(metadata, :cwd))
          |> Map.put(:env, env)

        {:ok,
         command
         |> CommandRunner.result(status, output, state.policy, Map.put(command_metadata, :exit_code, status))
         |> CommandRunner.put_stderr(stderr, state.policy), state}

      failure ->
        {:error, CommandRunner.failure(command, failure, command_metadata), state}
    end
  end

  defp session_script(command, metadata, env_path) do
    [
      command,
      "\n__beam_weaver_status=$?\n",
      "printf '%s\\n' \"$__beam_weaver_status\" > ",
      CommandRunner.shell_quote(metadata),
      "\n",
      "pwd >> ",
      CommandRunner.shell_quote(metadata),
      "\n",
      "env -0 > ",
      CommandRunner.shell_quote(env_path),
      "\n",
      "exit $__beam_weaver_status\n"
    ]
    |> IO.iodata_to_binary()
  end

  defp read_metadata(path) do
    case File.read(path) do
      {:ok, data} ->
        [status | rest] = String.split(data, "\n", parts: 3)
        %{status: safe_int(status), cwd: rest |> List.first() |> blank_to_nil()}

      {:error, _reason} ->
        %{}
    end
  end

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

  defp maybe_update_cwd(state, nil), do: state

  defp maybe_update_cwd(state, cwd) do
    cwd = Path.expand(cwd, state.cwd)
    if File.dir?(cwd), do: %{state | cwd: cwd}, else: state
  end

  defp cleanup_temp_root(%__MODULE__{temp_root: nil}), do: :ok
  defp cleanup_temp_root(%__MODULE__{temp_root: root}), do: File.rm_rf(root)

  defp call_timeout(pid, opts) do
    timeout =
      case Keyword.get(opts, :timeout) do
        nil -> GenServer.call(pid, :policy_timeout, :infinity)
        timeout -> timeout
      end

    case timeout do
      nil -> :infinity
      :infinity -> :infinity
      timeout when is_integer(timeout) -> timeout + CommandRunner.stop_budget() + 1_000
    end
  catch
    :exit, _reason -> :infinity
  end

  defp safe_int(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} -> int
      _other -> nil
    end
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: String.trim(value)
end
