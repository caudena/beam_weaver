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

  @default_subagent_prompt """
  In order to complete the objective that the user asks of you, you have access to a number of standard tools.

  The calling agent only sees your final assistant message, not your intermediate work, tool results, or status tracking. Ensure your final
  response contains the complete answer.
  """

  @default_general_purpose_description "General-purpose agent for researching complex questions, searching for files and content, and executing multi-step tasks. When you are searching for a keyword or file and are not confident that you will find the right match in the first few tries use this agent to perform the search for you. This agent has access to all tools as the main agent."

  @task_system_prompt """
  ## `task` (subagent spawner)

  You have access to a `task` tool to launch short-lived subagents that handle isolated tasks. These agents are ephemeral -- they live only for the duration of the task and return a single result.

  When to use the task tool:

  - When a task is complex and multi-step, and can be fully delegated in isolation
  - When a task is independent of other tasks and can run in parallel
  - When a task requires focused reasoning or heavy token/context usage that would bloat the orchestrator thread
  - When sandboxing improves reliability (e.g. code execution, structured searches, data formatting)
  - When you only care about the output of the subagent, and not the intermediate steps (ex. performing a lot of research and then returned a synthesized report, performing a series of computations or lookups to achieve a concise, relevant answer.)

  Subagent lifecycle:

  1. **Spawn** -> Provide clear role, instructions, and expected output
  2. **Run** -> The subagent completes the task autonomously
  3. **Return** -> The subagent provides a single structured result
  4. **Reconcile** -> Incorporate or synthesize the result into the main thread

  When NOT to use the task tool:

  - If you need to see the intermediate reasoning or steps after the subagent has completed (the task tool hides them)
  - If the task is trivial (a few tool calls or simple lookup)
  - If delegating does not reduce token usage, complexity, or context switching
  - If splitting would add latency without benefit

  ## Important Task Tool Usage Notes to Remember

  - Whenever possible, parallelize the work that you do. This is true for both tool_calls, and for tasks. Whenever you have independent steps to complete - make tool_calls, or kick off tasks (subagents) in parallel to accomplish them faster. This saves time for the user, which is incredibly important.
  - Remember to use the `task` tool to silo independent tasks within a multi-part objective.
  - You should use the `task` tool whenever you have a complex task that will take multiple steps, and is independent from other tasks that the agent needs to complete. These agents are highly competent and efficient.
  """

  @task_description """
  Launch an ephemeral subagent to handle complex, multi-step independent tasks with an isolated context window.

  Available agent types and the tools they have access to:
  %{available_agents}

  When using the Task tool, you must specify a subagent_type parameter to select which agent type to use.

  ## Usage notes:
  1. Launch multiple agents concurrently whenever possible, to maximize performance; to do that, use a single message with multiple tool uses
  2. When the agent is done, it will return a single message back to you. The result returned by the agent is not visible to the user. To show the user the result, you should send a text message back to the user with a concise summary of the result.
  3. Each agent invocation is stateless. You will not be able to send additional messages to the agent, nor will the agent be able to communicate with you outside of its final report. Therefore, your prompt should contain a highly detailed task description for the agent to perform autonomously and you should specify exactly what information the agent should return back to you in its final and only message to you.
  4. The agent's outputs should generally be trusted
  5. Clearly tell the agent whether you expect it to create content, perform analysis, or just do research (search, file reads, web fetches, etc.), since it is not aware of the user's intent
  6. If the agent description mentions that it should be used proactively, then you should try your best to use it without the user having to ask for it first. Use your judgement.
  7. When only the general-purpose agent is provided, you should use it for all tasks. It is great for isolating context and token usage, and completing specific, complex tasks, as it has all the same capabilities as the main agent.

  ### Example usage of the general-purpose agent:

  <example_agent_descriptions>
  "general-purpose": use this agent for general purpose tasks, it has access to all tools as the main agent.
  </example_agent_descriptions>

  <example>
  User: "I want to conduct research on the accomplishments of Lebron James, Michael Jordan, and Kobe Bryant, and then compare them."
  Assistant: *Uses the task tool in parallel to conduct isolated research on each of the three players*
  Assistant: *Synthesizes the results of the three isolated research tasks and responds to the User*
  <commentary>
  Research is a complex, multi-step task in it of itself.
  The research of each individual player is not dependent on the research of the other players.
  The assistant uses the task tool to break down the complex objective into three isolated tasks.
  Each research task only needs to worry about context and tokens about one player, then returns synthesized information about each player as the Tool Result.
  This means each research task can dive deep and spend tokens and context deeply researching each player, but the final result is synthesized information, and saves us tokens in the long run when comparing the players to each other.
  </commentary>
  </example>

  <example>
  User: "Analyze a single large code repository for security vulnerabilities and generate a report."
  Assistant: *Launches a single `task` subagent for the repository analysis*
  Assistant: *Receives report and integrates results into final summary*
  <commentary>
  Subagent is used to isolate a large, context-heavy task, even though there is only one. This prevents the main thread from being overloaded with details.
  If the user then asks followup questions, we have a concise report to reference instead of the entire history of analysis and tool calls, which is good and saves us time and money.
  </commentary>
  </example>

  <example>
  User: "Schedule two meetings for me and prepare agendas for each."
  Assistant: *Calls the task tool in parallel to launch two `task` subagents (one per meeting) to prepare agendas*
  Assistant: *Returns final schedules and agendas*
  <commentary>
  Tasks are simple individually, but subagents help silo agenda preparation.
  Each subagent only needs to worry about the agenda for one meeting.
  </commentary>
  </example>

  <example>
  User: "I want to order a pizza from Dominos, order a burger from McDonald's, and order a salad from Subway."
  Assistant: *Calls tools directly in parallel to order a pizza from Dominos, a burger from McDonald's, and a salad from Subway*
  <commentary>
  The assistant did not use the task tool because the objective is super simple and clear and only requires a few trivial tool calls.
  It is better to just complete the task directly and NOT use the `task` tool.
  </commentary>
  </example>

  ### Example usage with custom agents:

  <example_agent_descriptions>
  "content-reviewer": use this agent after you are done creating significant content or documents
  "greeting-responder": use this agent when to respond to user greetings with a friendly joke
  "research-analyst": use this agent to conduct thorough research on complex topics
  </example_agent_descriptions>

  <example>
  user: "Please write a function that checks if a number is prime"
  assistant: Sure let me write a function that checks if a number is prime
  assistant: First let me use the Write tool to write a function that checks if a number is prime
  assistant: I'm going to use the Write tool to write the following code:
  <code>
  function isPrime(n) {{
    if (n <= 1) return false
    for (let i = 2; i * i <= n; i++) {{
      if (n % i === 0) return false
    }}
    return true
  }}
  </code>
  <commentary>
  Since significant content was created and the task was completed, now use the content-reviewer agent to review the work
  </commentary>
  assistant: Now let me use the content-reviewer agent to review the code
  assistant: Uses the Task tool to launch with the content-reviewer agent
  </example>

  <example>
  user: "Can you help me research the environmental impact of different renewable energy sources and create a comprehensive report?"
  <commentary>
  This is a complex research task that would benefit from using the research-analyst agent to conduct thorough analysis
  </commentary>
  assistant: I'll help you research the environmental impact of renewable energy sources. Let me use the research-analyst agent to conduct comprehensive research on this topic.
  assistant: Uses the Task tool to launch with the research-analyst agent, providing detailed instructions about what research to conduct and what format the report should take
  </example>

  <example>
  user: "Hello"
  <commentary>
  Since the user is greeting, use the greeting-responder agent to respond with a friendly joke
  </commentary>
  assistant: "I'm going to use the Task tool to launch with the greeting-responder agent"
  </example>
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
      |> maybe_add_general_purpose_subagent(opts)
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
            "description" => %{
              "type" => "string",
              "description" =>
                "A detailed description of the task for the subagent to perform autonomously. Include all necessary context and specify the expected output format."
            },
            "subagent_type" => %{
              "type" => "string",
              "description" =>
                "The type of subagent to use. Must be one of the available agent types listed in the tool description."
            }
          },
          "required" => ["description", "subagent_type"],
          "additionalProperties" => false
        },
        injected: %{
          state: :state,
          tool_call_id: :tool_call_id,
          runtime: :runtime,
          tool_runtime: :tool_runtime
        },
        handler: fn input, _opts -> run_task(middleware, input) end,
        metadata: %{
          integration: :deepagents,
          kind: :subagent,
          trace_tools: subagent_trace_tools(middleware)
        }
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

  defp maybe_add_general_purpose_subagent(subagents, opts) do
    if Enum.any?(subagents, &(subagent_name(&1) == "general-purpose")) do
      subagents
    else
      [general_purpose_subagent(opts) | subagents]
    end
  end

  defp general_purpose_subagent(opts) do
    %Spec{
      name: "general-purpose",
      description: Keyword.get(opts, :general_purpose_description, @default_general_purpose_description),
      system_prompt: Keyword.get(opts, :general_purpose_system_prompt, @default_subagent_prompt),
      base_middleware: [:deepagents]
    }
  end

  defp subagent_name(%Compiled{name: name}), do: name
  defp subagent_name(%Spec{name: name}), do: name
  defp subagent_name(map) when is_map(map), do: value(map, :name)
  defp subagent_name(opts) when is_list(opts), do: Keyword.get(opts, :name)
  defp subagent_name(_other), do: nil

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
          "## Research Phase\nYou are in the RESEARCH phase. Your job is to call any tools you need to gather additional context (e.g., related deals). When done, summarize what you found in your final message.\nIf you don't need any additional data, just say 'No additional research needed.'"
      )

    generate_subagent = %{subagent | inherit_messages: false, base_middleware: []}

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
        prompt_suffix: nil
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
      [subagent.system_prompt, prompt_suffix]
      |> Enum.reject(&(is_nil(&1) or blank?(&1)))
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

  defp subagent_trace_tools(%__MODULE__{subagents: subagents}) do
    Enum.map(subagents, fn %Compiled{} = subagent ->
      %{
        name: subagent_tool_name(subagent.name),
        description: subagent_tool_description(subagent),
        input_schema: %{
          "type" => "object",
          "properties" => %{},
          "additionalProperties" => false
        },
        strict: true
      }
    end)
  end

  defp subagent_tool_name(name), do: "run_#{name}"

  defp subagent_tool_description(%Compiled{name: name, description: description}) do
    description = to_string(description || "")

    if String.trim(description) == "" do
      "Run the #{name} subagent with verification."
    else
      "Run the #{name} subagent with verification. #{description}"
    end
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

    if additional_research?(research_result) do
      """
      #{description}

      ## Additional Research Context
      #{research_result}
      """
    else
      description
    end
  end

  defp additional_research?(research_result) do
    text = research_result |> result_text() |> String.trim()
    text != "" and not String.contains?(String.downcase(text), "no additional research needed")
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
      subagent.base_middleware
      |> List.wrap()
      |> Enum.flat_map(
        &base_middleware_entry(&1, model, backend, permissions, skills, summarization, compact_conversation)
      )

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

  defp base_middleware_entry(:deepagents, model, backend, permissions, skills, summarization, compact_conversation) do
    [
      default_todo_list(),
      maybe_skills(backend, skills),
      filesystem_middleware(backend, permissions),
      maybe_summarization(model, backend, summarization),
      maybe_compact_conversation(model, backend || State.new(), summarization, compact_conversation)
    ]
  end

  defp base_middleware_entry(
         {TodoList, opts},
         _model,
         _backend,
         _permissions,
         _skills,
         _summarization,
         _compact_conversation
       ),
       do: [todo_list(opts)]

  defp base_middleware_entry(TodoList, _model, _backend, _permissions, _skills, _summarization, _compact_conversation),
    do: [default_todo_list()]

  defp base_middleware_entry(
         {Filesystem, opts},
         _model,
         backend,
         permissions,
         _skills,
         _summarization,
         _compact_conversation
       ),
       do: [filesystem_middleware(Keyword.get(opts, :backend, backend), Keyword.get(opts, :permissions, permissions))]

  defp base_middleware_entry(Filesystem, _model, backend, permissions, _skills, _summarization, _compact_conversation),
    do: [filesystem_middleware(backend, permissions)]

  defp base_middleware_entry(
         {Skills, opts},
         _model,
         backend,
         _permissions,
         skills,
         _summarization,
         _compact_conversation
       ),
       do: [maybe_skills(Keyword.get(opts, :backend, backend), Keyword.get(opts, :skills, skills))]

  defp base_middleware_entry(Skills, _model, backend, _permissions, skills, _summarization, _compact_conversation),
    do: [maybe_skills(backend, skills)]

  defp base_middleware_entry(
         {Summarization, opts},
         model,
         _backend,
         _permissions,
         _skills,
         _summarization,
         _compact_conversation
       ),
       do: [maybe_summarization(model, nil, opts)]

  defp base_middleware_entry(
         Summarization,
         model,
         _backend,
         _permissions,
         _skills,
         summarization,
         _compact_conversation
       ),
       do: [maybe_summarization(model, nil, summarization)]

  defp base_middleware_entry(
         {CompactConversation, opts},
         model,
         backend,
         _permissions,
         _skills,
         summarization,
         _compact_conversation
       ),
       do: [maybe_compact_conversation(model, backend || State.new(), summarization || true, opts)]

  defp base_middleware_entry(
         CompactConversation,
         model,
         backend,
         _permissions,
         _skills,
         summarization,
         compact_conversation
       ),
       do: [maybe_compact_conversation(model, backend || State.new(), summarization || true, compact_conversation)]

  defp base_middleware_entry(value, _model, _backend, _permissions, _skills, _summarization, _compact_conversation)
       when is_binary(value) do
    raise ArgumentError, "base_middleware entries must use atom or module values, got #{inspect(value)}"
  end

  defp base_middleware_entry(value, _model, _backend, _permissions, _skills, _summarization, _compact_conversation),
    do: [value]

  defp todo_list(settings) when is_list(settings) do
    settings
    |> Keyword.put_new(:tool_name, "write_todos")
    |> TodoList.new()
  end

  defp default_todo_list do
    TodoList.new(tool_name: "write_todos")
  end

  defp filesystem_middleware(nil, _permissions), do: nil

  defp filesystem_middleware(backend, permissions),
    do: Filesystem.new(backend: backend, permissions: permissions || [])

  defp maybe_model_call_limit(:structured_once), do: ModelCallLimit.new(run_limit: 1)
  defp maybe_model_call_limit(_execution_mode), do: nil

  defp subagent_backend(%Spec{filesystem: nil}, parent_backend), do: parent_backend
  defp subagent_backend(%Spec{filesystem: backend}, _parent_backend), do: backend

  defp normalize_execution_mode(nil), do: :agent_loop
  defp normalize_execution_mode(:agent_loop), do: :agent_loop
  defp normalize_execution_mode(:structured_once), do: :structured_once
  defp normalize_execution_mode(:research_then_generate), do: :research_then_generate

  defp normalize_execution_mode(mode) do
    raise ArgumentError,
          "unknown subagent execution_mode #{inspect(mode)}; expected :agent_loop, :structured_once, or :research_then_generate"
  end

  defp normalize_capture_output(value) when value in [nil, false], do: nil

  defp normalize_capture_output(value) when is_atom(value),
    do: capture_config(value, [])

  defp normalize_capture_output({key, opts}) when is_list(opts) or is_map(opts),
    do: capture_config(key, opts)

  defp normalize_capture_output(opts) when is_list(opts) or is_map(opts) do
    key =
      option_value(opts, :key) ||
        option_value(opts, :capture_key)

    capture_config(key, opts)
  end

  defp normalize_capture_output(value) do
    raise ArgumentError, "invalid capture_output #{inspect(value)}"
  end

  defp capture_config(nil, _opts), do: raise(ArgumentError, "capture_output requires a key")

  defp capture_config(key, _opts) when not is_atom(key) do
    raise ArgumentError, "capture_output key must be an atom, got #{inspect(key)}"
  end

  defp capture_config(key, opts) do
    %{
      key: to_string(key),
      dedupe: option_value(opts, :dedupe, true) != false,
      parent_result: normalize_parent_result(option_value(opts, :parent_result, :ack))
    }
  end

  defp normalize_parent_result(:full), do: :full
  defp normalize_parent_result(value) when value in [nil, :ack], do: :ack

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

    []
    |> maybe_put_opt(:context, runtime_value(runtime, :context))
    |> Keyword.put(:config, config)
    |> Keyword.put(:trace, subagent_trace(subagent, phase))
  end

  defp task_result_metadata(%Compiled{} = subagent, opts) do
    %{
      integration: :deepagents,
      kind: :subagent_result,
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

  defp subagent_trace(%Compiled{} = subagent, phase) do
    metadata =
      %{
        subagent_name: subagent.name,
        subagent_type: subagent.name,
        structured_output_strategy: subagent.structured_output_strategy
      }
      |> maybe_put_metadata(:subagent_phase, phase)
      |> maybe_put_metadata(:capture_key, subagent.capture_output && subagent.capture_output.key)

    [
      name: "deepagents.subagent.#{subagent.name}",
      execution_mode: to_string(subagent.execution_mode),
      metadata: metadata
    ]
  end

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

  defp maybe_decode_json_result(result) when is_binary(result) do
    case BeamWeaver.JSON.decode(result) do
      {:ok, decoded} -> decoded
      {:error, _error} -> result
    end
  end

  defp maybe_decode_json_result(result), do: result

  defp captured_parent_result(value) when is_binary(value), do: value
  defp captured_parent_result(value), do: BeamWeaver.JSON.encode!(value)

  defp capture_ack(%Compiled{}, _capture, _input_hash, _cached?), do: "{}"

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
    details = error.details

    ["Subagent error: #{error.message}", "type=#{inspect(error.type)}"]
    |> maybe_append_error_details(details)
    |> Enum.join(" ")
  end

  defp maybe_append_error_details(parts, details) when details == %{}, do: parts

  defp maybe_append_error_details(parts, details) do
    parts ++ ["details=#{inspect(details, limit: 20, printable_limit: 2_000)}"]
  end

  defp child_state_update(parent_state, child_state)
       when is_map(parent_state) and is_map(child_state) do
    child_state
    |> Enum.reject(fn {key, value} ->
      child_state_excluded_key?(key) or parent_state_value(parent_state, key) == value
    end)
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
