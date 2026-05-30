defmodule BeamWeaver.Agent.Middleware.Subagents do
  @moduledoc "Adds the DeepAgents `task` tool for synchronous subagents."

  @behaviour BeamWeaver.Agent.Middleware

  alias BeamWeaver.Agent.Builder
  alias BeamWeaver.Agent.Middleware.CompactConversation
  alias BeamWeaver.Agent.Middleware.Filesystem
  alias BeamWeaver.Agent.Middleware.HumanInTheLoop
  alias BeamWeaver.Agent.Middleware.ModelCallLimit
  alias BeamWeaver.Agent.Middleware.Skills
  alias BeamWeaver.Agent.Middleware.Summarization
  alias BeamWeaver.Agent.Middleware.TodoList
  alias BeamWeaver.Agent.Middleware.ToolCallNormalization
  alias BeamWeaver.Agent.ModelRequest
  alias BeamWeaver.Agent.Runner
  alias BeamWeaver.Agent.State, as: AgentState
  alias BeamWeaver.Agent.StructuredOutput
  alias BeamWeaver.Agent.StructuredOutput.ProviderStrategy
  alias BeamWeaver.Agent.StructuredOutput.ToolStrategy
  alias BeamWeaver.Agent.Subagent.Compiled
  alias BeamWeaver.Agent.Subagent.Spec
  alias BeamWeaver.Checkpoint
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Filesystem.State
  alias BeamWeaver.Graph
  alias BeamWeaver.Graph.Channels.BinaryOperatorAggregate
  alias BeamWeaver.Graph.Command
  alias BeamWeaver.Graph.Execution.Namespace

  require Logger

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
    :memory_contents,
    :subagent_outputs,
    :subagent_cache
  ]

  @child_state_exclusion_names MapSet.new(Enum.map(@child_state_exclusions, &Atom.to_string/1))

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
  def state_schema(_middleware) do
    %{
      subagent_outputs: Graph.channel({BinaryOperatorAggregate, &merge_maps/2}, initial: %{}),
      subagent_cache: Graph.channel({BinaryOperatorAggregate, &merge_maps/2}, initial: %{})
    }
  end

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
    parent_backend = Keyword.get(opts, :backend, State.new())
    backend = subagent_backend(subagent, parent_backend)
    parent_tools = Keyword.get(opts, :parent_tools, [])
    tools = subagent.tools || parent_tools || []
    permissions = subagent.permissions || Keyword.get(opts, :permissions, [])
    skills = subagent.skills || Keyword.get(opts, :skills, [])
    interrupt_on = subagent.interrupt_on || Keyword.get(opts, :interrupt_on)
    summarization = Keyword.get(opts, :summarization, true)
    compact_conversation = Keyword.get(opts, :compact_conversation, true)
    execution_mode = normalize_execution_mode(subagent.execution_mode)
    capture_output = normalize_capture_output(subagent.capture_output)

    structured_output_strategy =
      subagent
      |> subagent_structured_output_strategy(model, tools, execution_mode)

    {agent, generate_agent} =
      build_subagent_agents!(
        subagent,
        model,
        tools,
        backend,
        permissions,
        skills,
        interrupt_on,
        summarization,
        compact_conversation,
        execution_mode,
        Keyword.get(opts, :checkpointer)
      )

    %Compiled{
      name: subagent.name,
      description: subagent.description,
      agent: agent,
      generate_agent: generate_agent,
      tool_count: length(List.wrap(tools)),
      inherit_messages: subagent.inherit_messages == true,
      capture_output: capture_output,
      execution_mode: execution_mode,
      structured_output_strategy: structured_output_strategy
    }
  end

  defp normalize_subagent(map, opts) when is_map(map),
    do: map |> Spec.new() |> normalize_subagent(opts)

  defp normalize_subagent(opts, build_opts) when is_list(opts),
    do: opts |> Spec.new() |> normalize_subagent(build_opts)

  defp subagent_structured_output_strategy(%Spec{} = subagent, model, _tools, :research_then_generate),
    do: structured_output_strategy(subagent.response_format, model, [])

  defp subagent_structured_output_strategy(%Spec{} = subagent, model, tools, _execution_mode),
    do: structured_output_strategy(subagent.response_format, model, tools)

  defp structured_output_strategy(nil, _model, _tools), do: nil

  defp structured_output_strategy(response_format, model, tools) do
    response_format
    |> StructuredOutput.normalize()
    |> StructuredOutput.effective_strategy(model, tools)
    |> structured_output_strategy_name()
  end

  defp structured_output_strategy_name(%ProviderStrategy{}), do: :provider
  defp structured_output_strategy_name(%ToolStrategy{}), do: :tool
  defp structured_output_strategy_name(_strategy), do: nil

  defp build_subagent_agents!(
         %Spec{} = subagent,
         model,
         tools,
         backend,
         permissions,
         skills,
         interrupt_on,
         summarization,
         compact_conversation,
         :research_then_generate,
         checkpointer
       ) do
    research_agent =
      build_subagent_agent!(
        subagent,
        name_suffix: "research",
        model: model,
        tools: tools,
        backend: backend,
        permissions: permissions,
        skills: skills,
        interrupt_on: interrupt_on,
        summarization: summarization,
        compact_conversation: compact_conversation,
        execution_mode: :agent_loop,
        response_format: nil,
        checkpointer: checkpointer,
        prompt_suffix:
          "First perform any necessary tool-enabled research or side effects. Return concise research notes for the final structured generation pass."
      )

    generate_subagent = %{
      subagent
      | base_middleware: [],
        filesystem: false,
        todo_list: false,
        inherit_messages: false
    }

    generate_agent =
      build_subagent_agent!(
        generate_subagent,
        name_suffix: "generate",
        model: model,
        tools: [],
        backend: nil,
        permissions: [],
        skills: [],
        interrupt_on: interrupt_on,
        summarization: false,
        compact_conversation: false,
        execution_mode: :structured_once,
        response_format: subagent.response_format,
        checkpointer: checkpointer,
        prompt_suffix:
          "Generate the required structured output from the supplied task and research notes. Do not call tools."
      )

    {research_agent, generate_agent}
  end

  defp build_subagent_agents!(
         %Spec{} = subagent,
         model,
         tools,
         backend,
         permissions,
         skills,
         interrupt_on,
         summarization,
         compact_conversation,
         execution_mode,
         checkpointer
       ) do
    agent =
      build_subagent_agent!(
        subagent,
        name_suffix: nil,
        model: model,
        tools: tools,
        backend: backend,
        permissions: permissions,
        skills: skills,
        interrupt_on: interrupt_on,
        summarization: summarization,
        compact_conversation: compact_conversation,
        execution_mode: execution_mode,
        response_format: subagent.response_format,
        checkpointer: checkpointer,
        prompt_suffix: nil
      )

    {agent, nil}
  end

  defp build_subagent_agent!(%Spec{} = subagent, opts) do
    name_suffix = Keyword.get(opts, :name_suffix)
    prompt_suffix = Keyword.get(opts, :prompt_suffix)

    name =
      ["deepagents.subagent.#{subagent.name}", name_suffix]
      |> Enum.reject(&blank?/1)
      |> Enum.join(".")

    system_prompt =
      [subagent.system_prompt, @subagent_prompt, prompt_suffix]
      |> Enum.reject(&is_nil/1)
      |> Enum.reject(&blank?/1)
      |> Enum.join("\n\n")

    {:ok, agent} =
      Builder.build(
        name: name,
        model: Keyword.fetch!(opts, :model),
        tools: Keyword.fetch!(opts, :tools),
        middleware:
          subagent_middleware(
            subagent,
            subagent.middleware || [],
            Keyword.fetch!(opts, :model),
            Keyword.fetch!(opts, :backend),
            Keyword.fetch!(opts, :permissions),
            Keyword.fetch!(opts, :skills),
            Keyword.fetch!(opts, :interrupt_on),
            Keyword.fetch!(opts, :summarization),
            Keyword.fetch!(opts, :compact_conversation),
            Keyword.fetch!(opts, :execution_mode)
          ),
        system_prompt: system_prompt,
        response_format: Keyword.fetch!(opts, :response_format),
        checkpointer: Keyword.fetch!(opts, :checkpointer),
        recursion_limit: 9999
      )

    agent
  end

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
      %Compiled{} = subagent ->
        input_hash = input_hash(description)

        case capture_cache(parent_state, subagent.capture_output, subagent.name, input_hash) do
          {:hit, cache} ->
            cached_task_output(input, cache, subagent, input_hash)

          :miss ->
            case invoke_subagent(subagent, parent_state, description, input) do
              {:ok, state} ->
                result = subagent_result(state)

                task_output(input, parent_state, state, result, subagent,
                  input_hash: input_hash,
                  cached?: false
                )

              {:interrupted, state} ->
                "Subagent interrupted: #{inspect(state)}"

              {:error, %Error{} = error} ->
                format_subagent_error(error)
            end
        end

      nil ->
        allowed = Enum.map_join(subagents, ", ", &"`#{&1.name}`")

        "We cannot invoke subagent #{name} because it does not exist, the only allowed types are #{allowed}"
    end
  end

  defp invoke_subagent(%Compiled{agent: agent} = subagent, parent_state, description, input)
       when subagent.execution_mode != :research_then_generate or is_nil(subagent.generate_agent) do
    Runner.invoke(
      agent,
      child_state(parent_state, description, subagent),
      child_invoke_opts(input, subagent)
    )
  end

  defp invoke_subagent(
         %Compiled{execution_mode: :research_then_generate, agent: research_agent, generate_agent: generate_agent} =
           subagent,
         parent_state,
         description,
         input
       ) do
    Logger.debug("#{subagent.name} using agent loop with #{subagent.tool_count || 0} tools")

    case Runner.invoke(
           research_agent,
           child_state(parent_state, description, subagent),
           child_invoke_opts(input, subagent, "research")
         ) do
      {:ok, research_state} ->
        research_result = subagent_result(research_state)
        log_research_result(subagent.name, research_result)
        generate_description = research_then_generate_description(description, research_result)

        case Runner.invoke(
               generate_agent,
               child_state(parent_state, generate_description, %{subagent | inherit_messages: false}),
               child_invoke_opts(input, subagent, "generate")
             ) do
          {:ok, generate_state} -> {:ok, Map.merge(research_state, generate_state)}
          other -> other
        end

      other ->
        other
    end
  end

  defp log_research_result(subagent_name, research_result) do
    text = to_string(research_result || "")

    if String.downcase(text) =~ "no additional research needed" or String.trim(text) == "" do
      Logger.debug("#{subagent_name} research phase: no additional data gathered")
    else
      Logger.debug("#{subagent_name} research phase returned #{String.length(text)} chars of additional context")
    end
  end

  defp research_then_generate_description(description, research_result) do
    research_result = result_text(research_result)

    """
    Original task:
    #{description}

    Tool-enabled research notes:
    #{research_result}

    Return the required structured output now.
    """
  end

  defp subagent_middleware(
         subagent,
         user_middleware,
         model,
         backend,
         permissions,
         skills,
         interrupt_on,
         summarization,
         compact_conversation,
         execution_mode
       ) do
    base_middleware =
      if deepagents_base_middleware?(subagent.base_middleware) do
        [
          maybe_todo_list(subagent.todo_list),
          maybe_skills(backend, skills),
          maybe_filesystem(subagent.filesystem, backend, permissions),
          maybe_summarization(model, backend, summarization),
          maybe_compact_conversation(model, backend || State.new(), summarization, compact_conversation)
        ]
      else
        []
      end

    [
      base_middleware,
      ToolCallNormalization.new(),
      maybe_model_call_limit(execution_mode),
      List.wrap(user_middleware),
      maybe_hitl(interrupt_on)
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
  end

  defp maybe_todo_list(false), do: nil
  defp maybe_todo_list(nil), do: default_todo_list()
  defp maybe_todo_list(true), do: default_todo_list()

  defp maybe_todo_list(settings) when is_list(settings) do
    settings
    |> Keyword.put_new(:tool_name, "write_todos")
    |> Keyword.put_new(:tool_description, "Create and update the DeepAgents TODO list.")
    |> TodoList.new()
  end

  defp maybe_todo_list(_other), do: default_todo_list()

  defp default_todo_list do
    TodoList.new(
      tool_name: "write_todos",
      tool_description: "Create and update the DeepAgents TODO list."
    )
  end

  defp maybe_filesystem(false, _backend, _permissions), do: nil
  defp maybe_filesystem(_filesystem, nil, _permissions), do: nil

  defp maybe_filesystem(_filesystem, backend, permissions),
    do: Filesystem.new(backend: backend, permissions: permissions || [])

  defp maybe_model_call_limit(:structured_once), do: ModelCallLimit.new(run_limit: 1)
  defp maybe_model_call_limit(_execution_mode), do: nil

  defp subagent_backend(%Spec{filesystem: false}, _parent_backend), do: nil
  defp subagent_backend(%Spec{filesystem: nil}, parent_backend), do: parent_backend
  defp subagent_backend(%Spec{filesystem: backend}, _parent_backend), do: backend

  defp deepagents_base_middleware?(value) when value in [nil, true, :deepagents, "deepagents"],
    do: true

  defp deepagents_base_middleware?(value) when value in [false, []], do: false
  defp deepagents_base_middleware?(_value), do: true

  defp normalize_execution_mode(nil), do: :agent_loop
  defp normalize_execution_mode(mode) when mode in [:agent_loop, "agent_loop"], do: :agent_loop
  defp normalize_execution_mode(mode) when mode in [:structured_once, "structured_once"], do: :structured_once

  defp normalize_execution_mode(mode) when mode in [:research_then_generate, "research_then_generate"],
    do: :research_then_generate

  defp normalize_execution_mode(mode) do
    raise ArgumentError,
          "unknown subagent execution_mode #{inspect(mode)}; expected :agent_loop, :structured_once, or :research_then_generate"
  end

  defp normalize_capture_output(value) when value in [nil, false], do: nil

  defp normalize_capture_output(value) when is_atom(value) or is_binary(value),
    do: capture_config(value, [])

  defp normalize_capture_output({key, opts}) when is_list(opts) or is_map(opts),
    do: capture_config(key, opts)

  defp normalize_capture_output(opts) when is_list(opts) or is_map(opts) do
    key =
      option_value(opts, :key) ||
        option_value(opts, "key") ||
        option_value(opts, :capture_key) ||
        option_value(opts, "capture_key")

    capture_config(key, opts)
  end

  defp normalize_capture_output(value) do
    raise ArgumentError, "invalid capture_output #{inspect(value)}"
  end

  defp capture_config(nil, _opts), do: raise(ArgumentError, "capture_output requires a key")

  defp capture_config(key, opts) do
    %{
      key: to_string(key),
      dedupe: option_value(opts, :dedupe, option_value(opts, "dedupe", true)) != false,
      parent_result:
        normalize_parent_result(option_value(opts, :parent_result, option_value(opts, "parent_result", :ack)))
    }
  end

  defp normalize_parent_result(value) when value in [:full, "full"], do: :full
  defp normalize_parent_result(value) when value in [nil, :ack, "ack"], do: :ack

  defp normalize_parent_result(value) do
    raise ArgumentError, "invalid capture_output parent_result #{inspect(value)}; expected :ack or :full"
  end

  defp option_value(opts, key, default \\ nil)
  defp option_value(opts, key, default) when is_list(opts) and is_atom(key), do: Keyword.get(opts, key, default)

  defp option_value(opts, key, default) when is_list(opts) do
    case Enum.find(opts, fn
           {entry_key, _value} -> entry_key == key
           _other -> false
         end) do
      {_key, value} -> value
      nil -> default
    end
  end

  defp option_value(opts, key, default) when is_map(opts), do: Map.get(opts, key, default)
  defp option_value(_opts, _key, default), do: default

  defp merge_maps(left, right), do: Map.merge(left || %{}, right || %{})

  defp maybe_skills(_backend, skills) when skills in [nil, []], do: nil
  defp maybe_skills(nil, _skills), do: nil
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

  defp child_state(parent_state, description, %Compiled{inherit_messages: true}) when is_map(parent_state) do
    parent_messages =
      parent_state
      |> parent_state_value(:messages)
      |> List.wrap()
      |> stable_parent_messages()

    parent_state
    |> Enum.reject(fn {key, _value} -> key != :messages and child_state_excluded_key?(key) end)
    |> Map.new()
    |> Map.put(:messages, parent_messages ++ [Message.user(description)])
  end

  defp child_state(parent_state, description, _subagent) when is_map(parent_state) do
    parent_state
    |> Enum.reject(fn {key, _value} -> child_state_excluded_key?(key) end)
    |> Map.new()
    |> Map.put(:messages, [Message.user(description)])
  end

  defp child_state(_parent_state, description, _subagent), do: %{messages: [Message.user(description)]}

  defp stable_parent_messages(messages) do
    Enum.filter(messages, &stable_parent_message?/1)
  end

  defp stable_parent_message?(%Message{role: :tool}), do: false

  defp stable_parent_message?(%Message{role: :assistant} = message) do
    not non_empty_list?(message.tool_calls) and not non_empty_list?(message.server_tool_calls)
  end

  defp stable_parent_message?(%Message{}), do: true

  defp stable_parent_message?(%{} = message) do
    role = value(message, :role)

    cond do
      role in [:tool, "tool"] ->
        false

      role in [:assistant, "assistant"] ->
        not non_empty_list?(value(message, :tool_calls)) and
          not non_empty_list?(value(message, :server_tool_calls))

      true ->
        true
    end
  end

  defp stable_parent_message?(_message), do: true

  defp non_empty_list?(value), do: is_list(value) and value != []

  defp task_output(input, parent_state, child_state, result, %Compiled{capture_output: nil} = subagent, _opts) do
    merge = child_state_update(parent_state, child_state)
    emit_task_result(input, merge, result, subagent, cached?: false)
  end

  defp task_output(
         input,
         parent_state,
         child_state,
         result,
         %Compiled{capture_output: capture} = subagent,
         opts
       ) do
    input_hash = Keyword.fetch!(opts, :input_hash)
    captured = child_state |> captured_result(result) |> json_safe_value()
    cache_key = cache_key(subagent.name, input_hash)

    merge =
      parent_state
      |> child_state_update(child_state)
      |> merge_maps(%{
        subagent_outputs: %{capture.key => captured},
        subagent_cache: capture_cache_update(capture, cache_key, captured)
      })

    content =
      case capture.parent_result do
        :full -> captured_parent_result(captured)
        :ack -> capture_ack(subagent, capture, input_hash, Keyword.get(opts, :cached?, false))
      end

    emit_task_result(input, merge, content, subagent,
      cached?: Keyword.get(opts, :cached?, false),
      capture_key: capture.key,
      input_hash: input_hash
    )
  end

  defp cached_task_output(input, cache, %Compiled{capture_output: capture} = subagent, input_hash) do
    content =
      case capture.parent_result do
        :full -> captured_parent_result(cache.output)
        :ack -> capture_ack(subagent, capture, input_hash, true)
      end

    emit_task_result(input, %{subagent_outputs: %{capture.key => cache.output}}, content, subagent,
      cached?: true,
      capture_key: capture.key,
      input_hash: input_hash
    )
  end

  defp emit_task_result(input, merge, result, %Compiled{} = subagent, metadata_opts) do
    tool_call_id = value(input, :tool_call_id)

    if is_binary(tool_call_id) and tool_call_id != "" do
      message =
        Message.tool(result,
          tool_call_id: tool_call_id,
          name: "task",
          metadata: task_result_metadata(subagent, metadata_opts)
        )

      %Command{update: Map.put(merge, :messages, [message])}
    else
      result
    end
  end

  defp child_invoke_opts(input, %Compiled{} = subagent, phase \\ nil) do
    runtime = runtime_from_input(input)
    config = child_config(runtime, input, subagent.name, phase)

    config =
      put_in(
        config,
        [Access.key("configurable", %{}), "ls_agent_type"],
        "subagent"
      )
      |> put_in([Access.key("configurable", %{}), "lc_agent_name"], "deepagents.subagent.#{subagent.name}")
      |> put_in([Access.key("configurable", %{}), "subagent_name"], subagent.name)
      |> put_in([Access.key("configurable", %{}), "execution_mode"], to_string(subagent.execution_mode))
      |> maybe_put_configurable("structured_output_strategy", subagent.structured_output_strategy)
      |> maybe_put_configurable("subagent_phase", phase)
      |> maybe_put_configurable("capture_key", subagent.capture_output && subagent.capture_output.key)

    []
    |> maybe_put_opt(:context, runtime_value(runtime, :context))
    |> Keyword.put(:config, config)
  end

  defp task_result_metadata(%Compiled{} = subagent, opts) do
    %{
      integration: :deepagents,
      kind: :subagent_result,
      lc_agent_type: "subagent",
      ls_agent_type: "subagent",
      lc_agent_name: "deepagents.subagent.#{subagent.name}",
      subagent_name: subagent.name,
      subagent_type: subagent.name,
      execution_mode: subagent.execution_mode,
      structured_output_strategy: subagent.structured_output_strategy,
      cache_hit: Keyword.get(opts, :cached?, false)
    }
    |> maybe_put_metadata(:capture_key, Keyword.get(opts, :capture_key))
    |> maybe_put_metadata(:input_hash, Keyword.get(opts, :input_hash))
  end

  defp maybe_put_metadata(metadata, _key, nil), do: metadata
  defp maybe_put_metadata(metadata, key, value), do: Map.put(metadata, key, value)

  defp capture_cache(_parent_state, nil, _subagent_name, _input_hash), do: :miss
  defp capture_cache(_parent_state, %{dedupe: false}, _subagent_name, _input_hash), do: :miss

  defp capture_cache(parent_state, capture, subagent_name, input_hash) when is_map(parent_state) do
    cache = state_map(parent_state, :subagent_cache)
    outputs = state_map(parent_state, :subagent_outputs)
    key = cache_key(subagent_name, input_hash)

    case Map.get(cache, key) do
      %{} = entry ->
        cache_entry_hit(entry)

      output_key when is_binary(output_key) ->
        legacy_cache_hit(outputs, capture.key, output_key)

      _other ->
        :miss
    end
  end

  defp capture_cache(_parent_state, _capture, _subagent_name, _input_hash), do: :miss

  defp capture_cache_update(%{dedupe: false}, _cache_key, _captured), do: %{}

  defp capture_cache_update(capture, cache_key, captured) do
    %{
      cache_key => %{
        "capture_key" => capture.key,
        "output" => captured
      }
    }
  end

  defp cache_entry_hit(entry) do
    case Map.get(entry, "output", Map.get(entry, :output)) do
      nil ->
        :miss

      output ->
        {:hit,
         %{
           output: output,
           output_key: Map.get(entry, "capture_key", Map.get(entry, :capture_key))
         }}
    end
  end

  defp legacy_cache_hit(outputs, capture_key, output_key) do
    cond do
      Map.has_key?(outputs, output_key) ->
        {:hit, %{output: Map.fetch!(outputs, output_key), output_key: output_key}}

      output_key == capture_key and Map.has_key?(outputs, capture_key) ->
        {:hit, %{output: Map.fetch!(outputs, capture_key), output_key: capture_key}}

      true ->
        :miss
    end
  end

  defp captured_result(child_state, result) when is_map(child_state) do
    case parent_state_value(child_state, :structured_response) do
      nil -> maybe_decode_json_result(result)
      response -> response
    end
  end

  defp captured_result(_child_state, result), do: maybe_decode_json_result(result)

  defp maybe_decode_json_result(result) when is_binary(result) do
    case BeamWeaver.JSON.decode(result) do
      {:ok, decoded} -> decoded
      {:error, _error} -> result
    end
  end

  defp maybe_decode_json_result(result), do: result

  defp captured_parent_result(value) when is_binary(value), do: value
  defp captured_parent_result(value), do: BeamWeaver.JSON.encode!(value)

  defp capture_ack(%Compiled{} = subagent, capture, input_hash, cached?) do
    BeamWeaver.JSON.encode!(%{
      "status" => "captured",
      "subagent_name" => subagent.name,
      "capture_key" => capture.key,
      "cache_hit" => cached?,
      "input_hash" => input_hash
    })
  end

  defp state_map(state, key) do
    case parent_state_value(state, key) do
      value when is_map(value) -> value
      _other -> %{}
    end
  end

  defp cache_key(subagent_name, input_hash), do: "#{subagent_name}:#{input_hash}"

  defp input_hash(input) do
    :crypto.hash(:sha256, to_string(input))
    |> Base.encode16(case: :lower)
  end

  defp json_safe_value(nil), do: nil
  defp json_safe_value(true), do: true
  defp json_safe_value(false), do: false
  defp json_safe_value(value) when is_binary(value) or is_number(value), do: value
  defp json_safe_value(value) when is_atom(value), do: Atom.to_string(value)

  defp json_safe_value(%Date{} = value), do: Date.to_iso8601(value)
  defp json_safe_value(%Time{} = value), do: Time.to_iso8601(value)
  defp json_safe_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp json_safe_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)

  defp json_safe_value(value) when is_list(value), do: Enum.map(value, &json_safe_value/1)

  defp json_safe_value(%{__struct__: _module} = value), do: inspect(value)

  defp json_safe_value(value) when is_map(value) do
    Map.new(value, fn {key, map_value} ->
      {to_string(key), json_safe_value(map_value)}
    end)
  end

  defp json_safe_value(value) when is_tuple(value), do: value |> Tuple.to_list() |> json_safe_value()
  defp json_safe_value(value), do: inspect(value)

  defp child_config(runtime, input, subagent_name, phase) do
    parent_config =
      runtime
      |> runtime_value(:config, %{})
      |> normalize_config()

    execution = runtime_value(runtime, :execution) || runtime_value(runtime, :execution_info) || %{}

    configurable =
      parent_config
      |> Checkpoint.configurable()
      |> put_configurable_from_execution("thread_id", execution, :thread_id)
      |> put_configurable_from_execution("checkpoint_ns", execution, :checkpoint_ns)
      |> put_configurable_from_execution("checkpoint_id", execution, :checkpoint_id)

    parent_config = Map.put(parent_config, "configurable", configurable)
    parent_ns = Map.get(configurable, "checkpoint_ns", "")
    child_ns = child_namespace(parent_ns, runtime, input, subagent_name, phase)

    checkpoint_map =
      configurable
      |> Map.get("checkpoint_map", %{})
      |> normalize_checkpoint_map()
      |> maybe_put_namespace_checkpoint(parent_ns, Map.get(configurable, "checkpoint_id"))

    child_configurable =
      configurable
      |> Map.put("checkpoint_ns", child_ns)
      |> Map.put("checkpoint_map", checkpoint_map)
      |> Map.delete("checkpoint_id")
      |> maybe_put_checkpoint_id(Map.get(checkpoint_map, child_ns))

    Map.put(parent_config, "configurable", child_configurable)
  end

  defp maybe_put_configurable(config, _key, nil), do: config

  defp maybe_put_configurable(config, key, value) do
    put_in(config, [Access.key("configurable", %{}), key], value)
  end

  defp child_namespace(parent_ns, runtime, input, subagent_name, phase) do
    parent_ns
    |> Namespace.child(runtime_value(runtime, :node, "task"), runtime_task_id(runtime, input))
    |> Namespace.child(subagent_namespace(subagent_name, phase), value(input, :tool_call_id))
    |> Namespace.serialize()
  end

  defp subagent_namespace(subagent_name, nil), do: "subagent.#{subagent_name}"
  defp subagent_namespace(subagent_name, phase), do: "subagent.#{subagent_name}.#{phase}"

  defp runtime_task_id(runtime, input) do
    runtime_value(runtime, :task_id) ||
      runtime_value(runtime_value(runtime, :execution, %{}), :task_id) ||
      value(input, :tool_call_id)
  end

  defp normalize_config(config) when is_list(config), do: normalize_config(Map.new(config))

  defp normalize_config(config) when is_map(config) do
    Map.new(config, fn {key, value} ->
      key = to_string(key)

      if key == "configurable" and is_map(value) do
        {key, stringify_keys(value)}
      else
        {key, value}
      end
    end)
  end

  defp normalize_config(_config), do: %{}

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp normalize_checkpoint_map(map) when is_map(map) do
    Map.new(map, fn {namespace, checkpoint_id} ->
      {Namespace.recast(namespace), checkpoint_id}
    end)
  end

  defp normalize_checkpoint_map(_other), do: %{}

  defp maybe_put_namespace_checkpoint(map, _namespace, nil), do: map

  defp maybe_put_namespace_checkpoint(map, namespace, checkpoint_id),
    do: Map.put(map, Namespace.recast(namespace), checkpoint_id)

  defp maybe_put_checkpoint_id(configurable, nil), do: configurable

  defp maybe_put_checkpoint_id(configurable, checkpoint_id),
    do: Map.put(configurable, "checkpoint_id", checkpoint_id)

  defp format_subagent_error(%Error{} = error) do
    details = error.details || %{}

    ["Subagent error: #{error.message}", "type=#{inspect(error.type)}"]
    |> maybe_append_error_details(details)
    |> Enum.join(" ")
  end

  defp maybe_append_error_details(parts, details) when details in [%{}, nil], do: parts

  defp maybe_append_error_details(parts, details) do
    parts ++ ["details=#{inspect(details, limit: 20, printable_limit: 2_000)}"]
  end

  defp child_state_update(parent_state, child_state)
       when is_map(parent_state) and is_map(child_state) do
    child_state
    |> Enum.reject(fn {key, _value} -> child_state_excluded_key?(key) end)
    |> Enum.reject(fn {key, value} -> parent_state_value(parent_state, key) == value end)
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
      %Message{role: :assistant} = message ->
        message
        |> Message.text()
        |> empty_to_nil()

      _other ->
        nil
    end) || ""
  end

  defp result_text(result) when is_binary(result), do: result
  defp result_text(%Message{} = message), do: Message.text(message)

  defp result_text(result) when is_list(result) do
    result
    |> Message.assistant()
    |> Message.text()
  rescue
    _exception -> inspect(result)
  end

  defp result_text(result), do: inspect(result)

  defp empty_to_nil(""), do: nil
  defp empty_to_nil(value), do: value

  defp blank?(value), do: is_nil(value) or String.trim(to_string(value)) == ""

  defp runtime_from_input(input) do
    tool_runtime = value(input, :tool_runtime)

    runtime =
      value(input, :runtime) ||
        runtime_value(tool_runtime, :runtime) ||
        %{}

    runtime
    |> normalize_runtime()
    |> maybe_put_runtime(:config, runtime_value(tool_runtime, :config))
    |> maybe_put_runtime(:context, runtime_value(tool_runtime, :context))
    |> maybe_put_runtime(:store, runtime_value(tool_runtime, :store))
    |> maybe_put_runtime(:checkpointer, runtime_value(tool_runtime, :checkpointer))
    |> maybe_put_runtime(
      :execution,
      runtime_value(tool_runtime, :execution) || runtime_value(tool_runtime, :execution_info)
    )
  end

  defp runtime_value(runtime, key, default \\ nil)

  defp runtime_value(runtime, key, default) when is_map(runtime),
    do: BeamWeaver.MapAccess.get(runtime, key, default)

  defp runtime_value(_runtime, _key, default), do: default

  defp normalize_runtime(%{__struct__: _module} = runtime), do: Map.from_struct(runtime)
  defp normalize_runtime(runtime) when is_map(runtime), do: runtime
  defp normalize_runtime(_runtime), do: %{}

  defp maybe_put_runtime(runtime, _key, nil), do: runtime

  defp maybe_put_runtime(runtime, key, value) do
    if runtime_value(runtime, key) in [nil, ""] do
      Map.put(runtime, key, value)
    else
      runtime
    end
  end

  defp put_configurable_from_execution(configurable, key, execution, execution_key) do
    case {Map.get(configurable, key), runtime_value(execution, execution_key)} do
      {missing, value} when missing in [nil, ""] and value not in [nil, ""] ->
        Map.put(configurable, key, value)

      _other ->
        configurable
    end
  end

  defp child_state_excluded_key?(key), do: MapSet.member?(@child_state_exclusion_names, to_string(key))

  defp parent_state_value(parent_state, key) when is_atom(key) do
    Map.get(parent_state, key, Map.get(parent_state, Atom.to_string(key)))
  end

  defp parent_state_value(parent_state, key) when is_binary(key) do
    Map.get(parent_state, key) || parent_state_atom_value(parent_state, key)
  end

  defp parent_state_value(parent_state, key), do: Map.get(parent_state, key)

  defp parent_state_atom_value(parent_state, key) do
    Map.get(parent_state, String.to_existing_atom(key))
  rescue
    ArgumentError -> nil
  end

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)
end
