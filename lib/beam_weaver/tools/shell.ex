defmodule BeamWeaver.Tools.Shell do
  @moduledoc """
  Policy-governed shell tool.
  """

  @behaviour BeamWeaver.Core.Tool

  alias BeamWeaver.Core.Error
  alias BeamWeaver.ShellPolicy

  @default_name "shell"
  @default_description "Run an explicitly allowed shell command."
  @state_arg :__beam_weaver_shell_state

  defstruct [:policy, name: @default_name, description: @default_description, session_key: nil]

  def new(opts \\ []) do
    %__MODULE__{
      policy: ShellPolicy.new!(Keyword.fetch!(opts, :policy)),
      name: Keyword.get(opts, :name, @default_name),
      description: Keyword.get(opts, :description, @default_description),
      session_key: Keyword.get(opts, :session_key)
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
  def injected(%__MODULE__{}), do: %{@state_arg => :state}

  @impl true
  def return_direct(_tool), do: false

  @impl true
  def response_format(_tool), do: nil

  @impl true
  def output_schema(_tool), do: %{"type" => "object"}

  @impl true
  def tags(_tool), do: [:shell]

  @impl true
  def metadata(_tool), do: %{policy: :explicit}

  @impl true
  def provider_opts(_tool), do: %{}

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
      executor = policy.executor

      if is_atom(executor) do
        executor.run(command, policy, opts)
      else
        executor.__struct__.run(executor, command, policy, opts)
      end
    end
  end

  defp do_session_invoke(%__MODULE__{session_key: session_key}, input, opts) do
    state = Map.get(input, @state_arg)
    session = fetch_session(state, session_key)

    cond do
      not is_pid(session) ->
        {:error,
         Error.new(:shell_session_missing, "shell session is not available in agent state", %{
           session_key: session_key
         })}

      truthy?(Map.get(input, "restart") || Map.get(input, :restart)) ->
        case BeamWeaver.Tools.Shell.Session.restart(session, opts) do
          :ok -> {:ok, %{status: 0, output: "Shell session restarted."}}
          {:error, %Error{} = error} -> {:error, error}
        end

      true ->
        command = Map.get(input, "command") || Map.get(input, :command)
        do_session_command(session, command, opts)
    end
  end

  defp do_session_command(_session, command, _opts) when not is_binary(command) do
    {:error, Error.new(:invalid_shell_command, "shell tool expects a command string")}
  end

  defp do_session_command(_session, command, _opts) when command == "" do
    {:error, Error.new(:invalid_shell_command, "shell command cannot be empty")}
  end

  defp do_session_command(session, command, opts) do
    BeamWeaver.Tools.Shell.Session.execute(session, command, opts)
  end

  defp fetch_session(state, key) when is_map(state) do
    Map.get(state, key) || Map.get(state, to_string(key))
  end

  defp fetch_session(_state, _key), do: nil

  defp truthy?(value), do: value in [true, "true", 1, "1"]
end
