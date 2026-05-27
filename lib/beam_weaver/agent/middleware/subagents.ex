defmodule BeamWeaver.Agent.Middleware.Subagents do
  @moduledoc "Adds the DeepAgents `task` tool for synchronous subagents."

  @behaviour BeamWeaver.Agent.Middleware

  alias BeamWeaver.Agent.Builder
  alias BeamWeaver.Agent.Middleware.CompactConversation
  alias BeamWeaver.Agent.Middleware.Filesystem
  alias BeamWeaver.Agent.Middleware.HumanInTheLoop
  alias BeamWeaver.Agent.Middleware.Skills
  alias BeamWeaver.Agent.Middleware.Summarization
  alias BeamWeaver.Agent.Middleware.TodoList
  alias BeamWeaver.Agent.Middleware.ToolCallNormalization
  alias BeamWeaver.Agent.ModelRequest
  alias BeamWeaver.Agent.Runner
  alias BeamWeaver.Agent.State, as: AgentState
  alias BeamWeaver.Agent.Subagent.Compiled
  alias BeamWeaver.Agent.Subagent.Spec
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Filesystem.State
  alias BeamWeaver.Graph.Command

  import BeamWeaver.Agent.Subagent.Helpers,
    only: [append_prompt: 2, available_agents: 1, value: 2, value: 3]

  @subagent_prompt """
  You are running as a focused subagent. Complete the assigned task and return
  the result to the supervising agent.
  """

  @task_system_prompt """
  ## `task` (subagent spawner)

  You have access to a `task` tool to launch short-lived subagents that handle isolated tasks. These agents are ephemeral and return a single result.

  Use the tool for complex, multi-step, independent work where isolation reduces context pressure. Do not use it for trivial lookups or a few direct tool calls.
  """

  @task_description """
  Launch an ephemeral subagent to handle complex, multi-step independent tasks with an isolated context window.

  Available subagent types:
  %{available_agents}

  Provide `description` with all necessary context and either `subagent_type` or `subagent_name` with one of the available types.
  """

  @child_state_exclusions [
    :messages,
    :todos,
    :structured_response,
    :skills_metadata,
    :skills_load_errors,
    :memory_contents
  ]

  defstruct subagents: [],
            model: nil,
            backend: State.new(),
            parent_tools: [],
            permissions: [],
            skills: [],
            interrupt_on: nil,
            checkpointer: nil,
            summarization: true,
            compact_conversation: true,
            system_prompt: @task_system_prompt,
            task_description: @task_description

  def new(opts \\ []) do
    subagents =
      opts
      |> Keyword.get(:subagents, [])
      |> List.wrap()
      |> Enum.map(&normalize_subagent(&1, opts))
      |> validate_subagents!()

    %__MODULE__{
      subagents: subagents,
      model: Keyword.get(opts, :model),
      backend: Keyword.get(opts, :backend, State.new()),
      parent_tools: Keyword.get(opts, :parent_tools, []),
      permissions: Keyword.get(opts, :permissions, []),
      skills: Keyword.get(opts, :skills, []),
      interrupt_on: Keyword.get(opts, :interrupt_on),
      checkpointer: Keyword.get(opts, :checkpointer),
      summarization: Keyword.get(opts, :summarization, true),
      compact_conversation: Keyword.get(opts, :compact_conversation, true),
      system_prompt: Keyword.get(opts, :system_prompt) || @task_system_prompt,
      task_description: Keyword.get(opts, :task_description) || @task_description
    }
  end

  @impl true
  def name(_middleware), do: :deepagents_subagents

  @impl true
  def tools(%__MODULE__{} = middleware) do
    description =
      middleware.task_description
      |> to_string()
      |> String.replace("%{available_agents}", available_agents(middleware.subagents))

    [
      Tool.from_function!(
        name: "task",
        description: description,
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "subagent_name" => %{"type" => "string"},
            "subagent_type" => %{"type" => "string"},
            "description" => %{"type" => "string"}
          },
          "required" => ["description"]
        },
        injected: %{
          state: :state,
          tool_call_id: :tool_call_id,
          runtime: :runtime,
          tool_runtime: :tool_runtime
        },
        handler: fn input, _opts -> run_task(middleware, input) end,
        metadata: %{integration: :deepagents, kind: :subagent}
      )
    ]
  end

  def wrap_model_call(%__MODULE__{system_prompt: nil}, %ModelRequest{} = request, handler),
    do: handler.(request)

  def wrap_model_call(%__MODULE__{} = middleware, %ModelRequest{} = request, handler) do
    prompt =
      middleware.system_prompt <>
        "\n\nAvailable subagent types:\n\n" <> available_agents(middleware.subagents)

    request
    |> ModelRequest.override(system_message: append_prompt(request.system_message, prompt))
    |> handler.()
  end

  defp normalize_subagent(%Compiled{} = subagent, _opts), do: subagent

  defp normalize_subagent(%Spec{} = subagent, opts) do
    model = subagent.model || Keyword.fetch!(opts, :model)
    backend = Keyword.get(opts, :backend, State.new())
    parent_tools = Keyword.get(opts, :parent_tools, [])
    tools = subagent.tools || parent_tools || []
    permissions = subagent.permissions || Keyword.get(opts, :permissions, [])
    skills = subagent.skills || Keyword.get(opts, :skills, [])
    interrupt_on = subagent.interrupt_on || Keyword.get(opts, :interrupt_on)
    summarization = Keyword.get(opts, :summarization, true)
    compact_conversation = Keyword.get(opts, :compact_conversation, true)

    {:ok, agent} =
      Builder.build(
        name: "deepagents.subagent.#{subagent.name}",
        model: model,
        tools: tools,
        middleware:
          subagent_middleware(
            subagent.middleware || [],
            model,
            backend,
            permissions,
            skills,
            interrupt_on,
            summarization,
            compact_conversation
          ),
        system_prompt: Enum.reject([subagent.system_prompt, @subagent_prompt], &is_nil/1) |> Enum.join("\n\n"),
        response_format: subagent.response_format,
        checkpointer: Keyword.get(opts, :checkpointer),
        recursion_limit: 9999
      )

    %Compiled{name: subagent.name, description: subagent.description, agent: agent}
  end

  defp normalize_subagent(map, opts) when is_map(map),
    do: map |> Spec.new() |> normalize_subagent(opts)

  defp normalize_subagent(opts, build_opts) when is_list(opts),
    do: opts |> Spec.new() |> normalize_subagent(build_opts)

  defp validate_subagents!([]),
    do: raise(ArgumentError, "at least one subagent must be specified")

  defp validate_subagents!(subagents) do
    names = Enum.map(subagents, & &1.name)

    duplicates =
      names
      |> Enum.frequencies()
      |> Enum.filter(fn {_name, count} -> count > 1 end)
      |> Enum.map(fn {name, _count} -> name end)

    if duplicates != [] do
      raise ArgumentError, "duplicate subagent names: #{Enum.join(duplicates, ", ")}"
    end

    Enum.each(subagents, fn
      %Compiled{name: name, description: description, agent: agent} ->
        cond do
          blank?(name) -> raise ArgumentError, "subagent name is required"
          blank?(description) -> raise ArgumentError, "subagent #{name} description is required"
          is_nil(agent) -> raise ArgumentError, "compiled subagent #{name} agent is required"
          true -> :ok
        end
    end)

    subagents
  end

  defp run_task(%__MODULE__{subagents: subagents}, input) do
    name = value(input, :subagent_type) || value(input, :subagent_name) || value(input, :name)
    description = value(input, :description, "")
    parent_state = value(input, :state, %{}) || %{}

    case Enum.find(subagents, &(&1.name == name)) do
      %Compiled{agent: agent} ->
        case Runner.invoke(
               agent,
               child_state(parent_state, description),
               child_invoke_opts(input, name)
             ) do
          {:ok, state} ->
            result = subagent_result(state)
            task_output(input, parent_state, state, result, name)

          {:interrupted, state} ->
            "Subagent interrupted: #{inspect(state)}"

          {:error, error} ->
            "Subagent error: #{error.message}"
        end

      nil ->
        allowed = Enum.map_join(subagents, ", ", &"`#{&1.name}`")

        "We cannot invoke subagent #{name} because it does not exist, the only allowed types are #{allowed}"
    end
  end

  defp subagent_middleware(
         user_middleware,
         model,
         backend,
         permissions,
         skills,
         interrupt_on,
         summarization,
         compact_conversation
       ) do
    [
      TodoList.new(
        tool_name: "write_todos",
        tool_description: "Create and update the DeepAgents TODO list."
      ),
      maybe_skills(backend, skills),
      Filesystem.new(backend: backend, permissions: permissions || []),
      maybe_summarization(model, backend, summarization),
      maybe_compact_conversation(model, backend, summarization, compact_conversation),
      ToolCallNormalization.new(),
      List.wrap(user_middleware),
      maybe_hitl(interrupt_on)
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
  end

  defp maybe_skills(_backend, skills) when skills in [nil, []], do: nil
  defp maybe_skills(backend, skills), do: Skills.new(backend: backend, skills: skills)

  defp maybe_summarization(_model, _backend, summarization) when summarization in [nil, false],
    do: nil

  defp maybe_summarization(model, _backend, settings) when is_list(settings),
    do: Summarization.new(Keyword.put_new(settings, :model, model))

  defp maybe_summarization(model, _backend, _enabled),
    do: Summarization.new(model: model, trigger: {:messages, 20}, keep: {:messages, 8})

  defp maybe_compact_conversation(_model, _backend, summarization, _compact)
       when summarization in [nil, false],
       do: nil

  defp maybe_compact_conversation(_model, _backend, _summarization, compact)
       when compact in [nil, false],
       do: nil

  defp maybe_compact_conversation(model, backend, _summarization, settings)
       when is_list(settings) do
    settings
    |> Keyword.put_new(:model, model)
    |> Keyword.put_new(:backend, backend)
    |> CompactConversation.new()
  end

  defp maybe_compact_conversation(model, backend, _summarization, _enabled),
    do: CompactConversation.new(model: model, backend: backend)

  defp maybe_hitl(nil), do: nil
  defp maybe_hitl(false), do: nil
  defp maybe_hitl(interrupt_on), do: HumanInTheLoop.new(interrupt_on: interrupt_on)

  defp child_state(parent_state, description) when is_map(parent_state) do
    parent_state
    |> Map.drop(@child_state_exclusions)
    |> Map.put(:messages, [Message.user(description)])
  end

  defp child_state(_parent_state, description), do: %{messages: [Message.user(description)]}

  defp task_output(input, parent_state, child_state, result, name) do
    merge = child_state_update(parent_state, child_state)
    tool_call_id = value(input, :tool_call_id)

    if is_binary(tool_call_id) and tool_call_id != "" do
      message =
        Message.tool(result,
          tool_call_id: tool_call_id,
          name: "task",
          metadata: %{
            integration: :deepagents,
            kind: :subagent_result,
            lc_agent_type: "subagent",
            subagent_name: name,
            subagent_type: name
          }
        )

      %Command{update: Map.put(merge, :messages, [message])}
    else
      result
    end
  end

  defp child_invoke_opts(input, subagent_name) do
    runtime = value(input, :runtime) || tool_runtime_runtime(input) || %{}
    config = runtime_value(runtime, :config, %{})

    config =
      put_in(
        config,
        [Access.key(:configurable, %{}), :ls_agent_type],
        "subagent"
      )
      |> put_in([Access.key(:configurable, %{}), :subagent_name], subagent_name)

    []
    |> maybe_put_opt(:context, runtime_value(runtime, :context))
    |> Keyword.put(:config, config)
  end

  defp child_state_update(parent_state, child_state)
       when is_map(parent_state) and is_map(child_state) do
    child_state
    |> Map.drop(@child_state_exclusions)
    |> Enum.reject(fn {key, value} -> Map.get(parent_state, key) == value end)
    |> Map.new()
  end

  defp child_state_update(_parent_state, _child_state), do: %{}

  defp subagent_result(%{structured_response: response}) when not is_nil(response),
    do: BeamWeaver.JSON.encode!(response)

  defp subagent_result(state) do
    state
    |> AgentState.messages()
    |> Enum.reverse()
    |> Enum.find_value(fn
      %Message{role: :assistant, content: content} when content not in [nil, ""] -> content
      _other -> nil
    end) || ""
  end

  defp blank?(value), do: is_nil(value) or String.trim(to_string(value)) == ""

  defp tool_runtime_runtime(input) do
    case value(input, :tool_runtime) do
      %{runtime: runtime} -> runtime
      %{"runtime" => runtime} -> runtime
      _missing -> nil
    end
  end

  defp runtime_value(runtime, key, default \\ nil)

  defp runtime_value(runtime, key, default) when is_map(runtime),
    do: BeamWeaver.MapAccess.get(runtime, key, default)

  defp runtime_value(_runtime, _key, default), do: default

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)
end
