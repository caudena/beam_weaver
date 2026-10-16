defmodule BeamWeaver.Agent.Middleware.ShellTool do
  @moduledoc """
  Gives an agent a `shell` tool backed by one shell session per run, so `cd`
  and `export` carry over between commands.

  Options: `:policy` (required: a `BeamWeaver.ShellPolicy` or its options,
  which list the commands the model may run), `:workspace_root`,
  `:startup_commands`, `:shutdown_commands`, `:tool_name`, `:tool_description`
  and `:idle_timeout`. Startup and shutdown commands must pass the policy too.
  See [Sandboxes](sandboxes.md#shell-tool-and-policies).

  The session is supervised and, for a run with a thread id, registered under
  that thread, so a run paused for human review and resumed reuses the same
  session (or lazily starts a fresh one when it has gone). A session with no
  command for `:idle_timeout` milliseconds (default 15 minutes, `:infinity` to
  disable) stops on its own, so a run that never reaches `after_agent` does not
  leak it.
  """

  use BeamWeaver.Agent.Middleware

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Graph
  alias BeamWeaver.ShellPolicy
  alias BeamWeaver.Tools.Shell
  alias BeamWeaver.Tools.Shell.Session
  alias BeamWeaver.Tools.Shell.Sessions

  @default_idle_timeout :timer.minutes(15)

  defstruct workspace_root: nil,
            policy: nil,
            startup_commands: [],
            shutdown_commands: [],
            tool_name: "shell",
            tool_description: "Run an explicitly allowed shell command.",
            state_key: :shell_session,
            idle_timeout: @default_idle_timeout

  @type t :: %__MODULE__{}

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    policy =
      case Keyword.get(opts, :policy) do
        nil ->
          raise ArgumentError,
                "#{inspect(__MODULE__)} requires a :policy that lists the commands the model may run, " <>
                  "such as policy: [allow: [\"git status\", \"ls\"]]"

        policy ->
          ShellPolicy.new!(policy)
      end

    %__MODULE__{
      workspace_root: Keyword.get(opts, :workspace_root),
      policy: policy,
      startup_commands: normalize_commands(Keyword.get(opts, :startup_commands, [])),
      shutdown_commands: normalize_commands(Keyword.get(opts, :shutdown_commands, [])),
      tool_name: Keyword.get(opts, :tool_name, "shell"),
      tool_description: Keyword.get(opts, :tool_description, "Run an explicitly allowed shell command."),
      state_key: Keyword.get(opts, :state_key, :shell_session),
      idle_timeout: Keyword.get(opts, :idle_timeout, @default_idle_timeout)
    }
  end

  @impl true
  def name(_middleware), do: :shell_tool

  @impl true
  def state_schema(%__MODULE__{state_key: state_key}) do
    %{state_key => Graph.private_channel(BeamWeaver.Graph.Channels.LastValue)}
  end

  @impl true
  def tools(%__MODULE__{} = middleware) do
    [
      Shell.new(
        policy: middleware.policy,
        name: middleware.tool_name,
        description: middleware.tool_description,
        session_key: middleware.state_key,
        workspace_root: middleware.workspace_root,
        startup_commands: middleware.startup_commands,
        shutdown_commands: middleware.shutdown_commands,
        idle_timeout: middleware.idle_timeout
      )
    ]
  end

  @impl true
  def before_agent(%__MODULE__{} = middleware, state, runtime) do
    case existing_session(state, middleware.state_key) do
      pid when is_pid(pid) ->
        %{middleware.state_key => pid}

      _missing ->
        with {:ok, pid} <- start_session(middleware, runtime) do
          %{middleware.state_key => pid}
        end
    end
  end

  @impl true
  def after_agent(%__MODULE__{} = middleware, state, runtime) do
    # Stop the session from state (the ordinary path) and the one registered
    # for this run's thread (started lazily by the tool after a resume, when
    # before_agent did not run to put a pid in state). They are the same
    # process on an ordinary run, so stopping is idempotent.
    stop_session(existing_session(state, middleware.state_key))
    stop_session(keyed_session(runtime, middleware))
    %{middleware.state_key => nil}
  end

  defp stop_session(pid) when is_pid(pid), do: Session.shutdown(pid)
  defp stop_session(_pid), do: :ok

  defp keyed_session(runtime, %__MODULE__{} = middleware) do
    case session_key(runtime, middleware) do
      nil -> nil
      key -> with {:ok, pid} <- Sessions.fetch(key), do: pid, else: (_ -> nil)
    end
  end

  # Start (or, for a run with a thread id, fetch-or-start) the session under
  # the shared supervisor, so it is cleaned up when the VM stops and reused on
  # a resume rather than leaked.
  defp start_session(%__MODULE__{} = middleware, runtime) do
    opts = Shell.session_opts(Shell.new(tool_opts(middleware)))

    case session_key(runtime, middleware) do
      nil -> Sessions.start(opts)
      key -> Sessions.fetch_or_start(key, opts)
    end
  rescue
    exception ->
      {:error,
       Error.new(:shell_session_start_failed, "shell session could not be started", %{
         reason: Exception.message(exception)
       })}
  end

  defp tool_opts(%__MODULE__{} = middleware) do
    [
      policy: middleware.policy,
      name: middleware.tool_name,
      session_key: middleware.state_key,
      workspace_root: middleware.workspace_root,
      startup_commands: middleware.startup_commands,
      shutdown_commands: middleware.shutdown_commands,
      idle_timeout: middleware.idle_timeout
    ]
  end

  defp session_key(runtime, %__MODULE__{} = middleware) do
    case Sessions.thread_id(runtime_config(runtime)) do
      nil -> nil
      thread_id -> Sessions.key(thread_id, middleware.state_key, middleware.tool_name)
    end
  end

  defp runtime_config(%{config: config}), do: config
  defp runtime_config(_runtime), do: nil

  defp existing_session(state, key) when is_map(state), do: Map.get(state, key)
  defp existing_session(_state, _key), do: nil

  defp normalize_commands(nil), do: []
  defp normalize_commands(command) when is_binary(command), do: [command]
  defp normalize_commands(commands) when is_list(commands), do: Enum.map(commands, &to_string/1)
end
