defmodule BeamWeaver.Tools.Shell do
  @moduledoc """
  Policy-governed shell tool.

  `new/1` requires a `:policy`, a `BeamWeaver.ShellPolicy` or its options,
  which lists the commands the model may run. Each allowed command runs in a
  new shell, in the policy's `cwd`, with the minimal environment the policy
  describes.
  """

  use BeamWeaver.Core.Tool

  alias BeamWeaver.Core.Error
  alias BeamWeaver.ShellPolicy
  alias BeamWeaver.Tools.Shell.Sessions

  @default_name "shell"
  @default_description "Run an explicitly allowed shell command."
  @session_arg :__beam_weaver_shell_session
  @config_arg :__beam_weaver_shell_config

  defstruct [
    :policy,
    name: @default_name,
    description: @default_description,
    session_key: nil,
    workspace_root: nil,
    startup_commands: [],
    shutdown_commands: [],
    idle_timeout: :infinity
  ]

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
      policy: policy,
      name: Keyword.get(opts, :name, @default_name),
      description: Keyword.get(opts, :description, @default_description),
      session_key: Keyword.get(opts, :session_key),
      workspace_root: Keyword.get(opts, :workspace_root),
      startup_commands: Keyword.get(opts, :startup_commands, []),
      shutdown_commands: Keyword.get(opts, :shutdown_commands, []),
      idle_timeout: Keyword.get(opts, :idle_timeout, :infinity)
    }
  end

  @impl true
  def name(%__MODULE__{name: name}), do: name

  @impl true
  def description(%__MODULE__{description: description}), do: description

  @impl true
  def input_schema(%__MODULE__{session_key: nil}) do
    %{
      "type" => "object",
      "properties" => %{"command" => %{"type" => "string"}},
      "required" => ["command"]
    }
  end

  def input_schema(%__MODULE__{}) do
    %{
      "type" => "object",
      "properties" => %{
        "command" => %{"type" => "string"},
        "restart" => %{"type" => "boolean", "default" => false}
      },
      "required" => []
    }
  end

  @impl true
  def injected(%__MODULE__{session_key: nil}), do: %{}

  # The session lives in a private key of the agent's state, which a tool
  # reads by naming it. The run config is injected too, so the tool can find
  # (or lazily restart) its session by thread id when the state no longer holds
  # a live pid — after a human-review pause and resume, say.
  def injected(%__MODULE__{session_key: session_key}),
    do: %{@session_arg => {:state, session_key}, @config_arg => :config}

  @impl true
  def output_schema(_tool), do: %{"type" => "object"}

  @impl true
  def tags(_tool), do: [:shell]

  @impl true
  def metadata(_tool), do: %{policy: :explicit}

  @impl true
  def invoke(%__MODULE__{session_key: session_key} = tool, input, opts)
      when not is_nil(session_key) and is_map(input) do
    do_session_invoke(tool, input, opts)
  end

  def invoke(%__MODULE__{}, %{"restart" => true}, _opts) do
    {:error, Error.new(:shell_session_required, "shell restart requires a session")}
  end

  def invoke(%__MODULE__{}, %{restart: true}, _opts) do
    {:error, Error.new(:shell_session_required, "shell restart requires a session")}
  end

  def invoke(%__MODULE__{policy: policy}, %{"command" => command}, opts),
    do: do_invoke(policy, command, opts)

  def invoke(%__MODULE__{policy: policy}, %{command: command}, opts),
    do: do_invoke(policy, command, opts)

  def invoke(%__MODULE__{}, _input, _opts) do
    {:error, Error.new(:invalid_shell_command, "shell tool expects a command string")}
  end

  defp do_invoke(_policy, command, _opts) when not is_binary(command) do
    {:error, Error.new(:invalid_shell_command, "shell tool expects a command string")}
  end

  defp do_invoke(%ShellPolicy{} = policy, command, opts) do
    if String.trim(command) == "" do
      {:error, Error.new(:invalid_shell_command, "shell command cannot be empty")}
    else
      # Enforce the policy here, not only in the executor: a custom executor
      # may trust whatever it is handed, so the tool guarantees every command
      # it dispatches passed `ShellPolicy.check/2` first.
      with :ok <- ShellPolicy.check(policy, command) do
        run_with_executor(policy.executor, command, policy, opts)
      end
    end
  end

  defp run_with_executor(executor, command, policy, opts) when is_atom(executor),
    do: executor.run(command, policy, opts)

  defp run_with_executor(executor, command, policy, opts),
    do: executor.__struct__.run(executor, command, policy, opts)

  defp do_session_invoke(%__MODULE__{session_key: session_key} = tool, input, opts) do
    session = resolve_session(tool, input)

    cond do
      not is_pid(session) ->
        {:error,
         Error.new(:shell_session_missing, "shell session is not available in agent state", %{
           session_key: session_key
         })}

      truthy?(Map.get(input, "restart") || Map.get(input, :restart)) ->
        with :ok <- BeamWeaver.Tools.Shell.Session.restart(session, opts),
             do: {:ok, %{status: 0, output: "Shell session restarted."}}

      true ->
        command = Map.get(input, "command") || Map.get(input, :command)
        BeamWeaver.Tools.Shell.Session.execute(session, command, opts)
    end
  end

  # The session from state, if still alive; otherwise, when the run has a
  # thread id, the one registered for it (lazily started), so a resumed run
  # whose state no longer holds a live pid still gets a working session.
  defp resolve_session(%__MODULE__{} = tool, input) do
    case Map.get(input, @session_arg) do
      pid when is_pid(pid) ->
        if Process.alive?(pid), do: pid, else: keyed_session(tool, input)

      _missing ->
        keyed_session(tool, input)
    end
  end

  defp keyed_session(%__MODULE__{} = tool, input) do
    case Sessions.thread_id(Map.get(input, @config_arg)) do
      nil ->
        nil

      thread_id ->
        key = Sessions.key(thread_id, tool.session_key, tool.name)

        case Sessions.fetch_or_start(key, session_opts(tool)) do
          {:ok, pid} -> pid
          {:error, _reason} -> nil
        end
    end
  end

  @doc false
  def session_opts(%__MODULE__{} = tool) do
    [
      policy: tool.policy,
      workspace_root: tool.workspace_root,
      startup_commands: tool.startup_commands,
      shutdown_commands: tool.shutdown_commands,
      idle_timeout: tool.idle_timeout
    ]
  end

  defp truthy?(value), do: value in [true, "true", 1, "1"]
end
