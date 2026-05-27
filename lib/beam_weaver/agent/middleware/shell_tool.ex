defmodule BeamWeaver.Agent.Middleware.ShellTool do
  @moduledoc """
  Agent middleware that exposes a policy-governed persistent shell tool.

  The middleware owns a `BeamWeaver.Tools.Shell.Session` process for the agent
  run and injects the session PID through normal tool runtime state. This keeps
  shell lifetime, startup/shutdown commands, restart, and cleanup in BeamWeaver's
  middleware/process model instead of copying Python's mutable session objects.
  """

  @behaviour BeamWeaver.Agent.Middleware

  alias BeamWeaver.Core.Error
  alias BeamWeaver.ShellPolicy
  alias BeamWeaver.Tools.Shell
  alias BeamWeaver.Tools.Shell.Session

  defstruct workspace_root: nil,
            policy: nil,
            startup_commands: [],
            shutdown_commands: [],
            tool_name: "shell",
            tool_description: "Run an explicitly allowed shell command.",
            state_key: :shell_session

  @type t :: %__MODULE__{}

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    policy =
      opts
      |> Keyword.get(:policy, allow: [~r/.*/])
      |> ShellPolicy.new!()

    %__MODULE__{
      workspace_root: Keyword.get(opts, :workspace_root),
      policy: policy,
      startup_commands: normalize_commands(Keyword.get(opts, :startup_commands, [])),
      shutdown_commands: normalize_commands(Keyword.get(opts, :shutdown_commands, [])),
      tool_name: Keyword.get(opts, :tool_name, "shell"),
      tool_description: Keyword.get(opts, :tool_description, "Run an explicitly allowed shell command."),
      state_key: Keyword.get(opts, :state_key, :shell_session)
    }
  end

  @impl true
  def name(_middleware), do: :shell_tool

  @impl true
  def state_schema(%__MODULE__{state_key: state_key}) do
    %{
      state_key => %{
        type: :term,
        private?: true,
        reducer: :replace
      }
    }
  end

  @impl true
  def tools(%__MODULE__{} = middleware) do
    [
      Shell.new(
        policy: middleware.policy,
        name: middleware.tool_name,
        description: middleware.tool_description,
        session_key: middleware.state_key
      )
    ]
  end

  def before_agent(%__MODULE__{} = middleware, state, _runtime) do
    case existing_session(state, middleware.state_key) do
      pid when is_pid(pid) ->
        %{middleware.state_key => pid}

      _missing ->
        with {:ok, pid} <- start_session(middleware) do
          %{middleware.state_key => pid}
        end
    end
  end

  def after_agent(%__MODULE__{} = middleware, state, _runtime) do
    case existing_session(state, middleware.state_key) do
      pid when is_pid(pid) ->
        Session.shutdown(pid)
        %{middleware.state_key => nil}

      _missing ->
        nil
    end
  end

  @spec async_before_agent(t(), map(), term(), keyword()) :: Task.t()
  def async_before_agent(%__MODULE__{} = middleware, state, runtime, opts \\ []) do
    supervisor = Keyword.get(opts, :task_supervisor)

    if supervisor do
      Task.Supervisor.async(supervisor, fn -> before_agent(middleware, state, runtime) end)
    else
      Task.async(fn -> before_agent(middleware, state, runtime) end)
    end
  end

  @spec async_after_agent(t(), map(), term(), keyword()) :: Task.t()
  def async_after_agent(%__MODULE__{} = middleware, state, runtime, opts \\ []) do
    supervisor = Keyword.get(opts, :task_supervisor)

    if supervisor do
      Task.Supervisor.async(supervisor, fn -> after_agent(middleware, state, runtime) end)
    else
      Task.async(fn -> after_agent(middleware, state, runtime) end)
    end
  end

  defp start_session(%__MODULE__{} = middleware) do
    Session.start(
      policy: middleware.policy,
      workspace_root: middleware.workspace_root,
      startup_commands: middleware.startup_commands,
      shutdown_commands: middleware.shutdown_commands
    )
  rescue
    exception ->
      {:error,
       Error.new(:shell_session_start_failed, "shell session could not be started", %{
         reason: Exception.message(exception)
       })}
  end

  defp existing_session(state, key) when is_map(state) do
    Map.get(state, key) || Map.get(state, to_string(key))
  end

  defp existing_session(_state, _key), do: nil

  defp normalize_commands(nil), do: []
  defp normalize_commands(command) when is_binary(command), do: [command]
  defp normalize_commands(commands) when is_list(commands), do: Enum.map(commands, &to_string/1)
end
