defmodule BeamWeaver.Agent.Middleware.Subagents do
  @moduledoc """
  Adds the `task` tool, which hands work to a subagent and waits for its answer.

  The `subagents` declaration adds this middleware. Each subagent runs as a
  separate agent run inside the `task` call:

    * It starts from the parent's state, without `messages`, the parent's
      private keys and a few keys of the parent's own, such as `todos`; the
      keys it changes come back to the parent.
    * It saves its checkpoints with the parent's checkpointer, in the parent's
      thread under its own namespace, and uses the parent's store and
      `context:`, unless it declares its own checkpointer or store. With a
      checkpointer of its own, in a parent run without a thread, it saves in
      a thread named after the parent run's `run_id`.
    * It may take as many steps as the parent's recursion limit, unless it
      sets its own `recursion_limit`.
    * It runs its own middleware and capabilities, not the parent's.
    * When it pauses for human review, the parent run pauses with the
      subagent's review; resuming the parent resumes the subagent. A parent
      run without a checkpointer fails with `:missing_checkpointer` before it
      starts when a subagent, or a subagent of a subagent, reviews tool calls.
    * It is built when a `task` call runs it. `BeamWeaver.Agent.build/1`, or
      an agent module's first call, checks every subagent without building
      it, and fails with an `:invalid_subagent` error that names one that
      can't be built.
    * Its events reach the parent's stream under the namespace
      `["tools", "subagent.<name>"]`, with `subagent_name` and `tool_call_id`
      in the envelope metadata.

  It adds nothing to the system prompt unless given `system_prompt:`, which
  adds that text followed by the list of subagents. `task_description:`
  replaces the `task` tool's description, with the list of subagents in
  place of `%{available_agents}`.

  The subagents list may hold a `BeamWeaver.Agent.GeneralPurposeSubagentProfile`
  to configure or turn off the built-in `general-purpose` subagent. See
  [Subagents](subagents.md).
  """

  use BeamWeaver.Agent.Middleware

  alias BeamWeaver.Agent
  alias BeamWeaver.Agent.Builder
  alias BeamWeaver.Agent.Built
  alias BeamWeaver.Agent.Capabilities
  alias BeamWeaver.Agent.CapabilityProfile
  alias BeamWeaver.Agent.Compiler
  alias BeamWeaver.Agent.GeneralPurposeSubagentProfile
  alias BeamWeaver.Agent.Middleware
  alias BeamWeaver.Agent.Middleware.CompactConversation
  alias BeamWeaver.Agent.Middleware.Filesystem
  alias BeamWeaver.Agent.Middleware.ModelCallLimit
  alias BeamWeaver.Agent.Middleware.Skills
  alias BeamWeaver.Agent.Middleware.SubagentOutputs
  alias BeamWeaver.Agent.Middleware.Summarization
  alias BeamWeaver.Agent.Middleware.TodoList
  alias BeamWeaver.Agent.Middleware.ToolCallNormalization
  alias BeamWeaver.Agent.ModelRequest
  alias BeamWeaver.Agent.ModelResolver
  alias BeamWeaver.Agent.Nodes.Model.Prompt
  alias BeamWeaver.Agent.ProviderProfile
  alias BeamWeaver.Agent.Spec, as: AgentSpec
  alias BeamWeaver.Agent.State, as: AgentState
  alias BeamWeaver.Agent.StructuredOutput
  alias BeamWeaver.Agent.StructuredOutput.ProviderStrategy
  alias BeamWeaver.Agent.StructuredOutput.ToolStrategy
  alias BeamWeaver.Agent.Subagent.Compiled
  alias BeamWeaver.Agent.Subagent.Host
  alias BeamWeaver.Agent.Subagent.Host.Proposal
  alias BeamWeaver.Agent.Subagent.Spec
  alias BeamWeaver.Checkpoint
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Core.ID
  alias BeamWeaver.Core.Message
  alias BeamWeaver.Core.Tool
  alias BeamWeaver.Filesystem.State
  alias BeamWeaver.Graph
  alias BeamWeaver.Graph.Command
  alias BeamWeaver.Graph.Execution.ChannelLookup
  alias BeamWeaver.Graph.Execution.Namespace
  alias BeamWeaver.Graph.Execution.Replay
  alias BeamWeaver.Graph.Execution.SubgraphRouter
  alias BeamWeaver.Graph.ModuleRunner
  alias BeamWeaver.Graph.StateGraph
  alias BeamWeaver.MapShape
  alias BeamWeaver.Stream.Sink

  import BeamWeaver.Agent.Middleware.Helpers, only: [append_prompt: 2]
  import BeamWeaver.Agent.Subagent.Helpers, only: [available_agents: 1, value: 2, value: 3]

  @default_subagent_prompt """
  In order to complete the objective that the user asks of you, you have access to a number of standard tools.

  The calling agent only sees your final assistant message, not your intermediate work, tool results, or status tracking. Ensure your final
  response contains the complete answer.\
  """

  @default_general_purpose_description "General-purpose agent for researching complex questions, searching for files and content, and executing multi-step tasks. When you are searching for a keyword or file and are not confident that you will find the right match in the first few tries use this agent to perform the search for you. This agent has access to all tools as the main agent."

  @task_description """
  Launch a short-lived subagent to handle a complex, multi-step task in a context window of its own.

  Available agent types:
  %{available_agents}

  Set subagent_type to one of these names. Usage notes:
  - When tasks are independent, launch several agents at once, with several tool calls in one message.
  - Each call is stateless, unless the agent's line says it sees your conversation: the agent sees only your description and returns one final report. Put every detail it needs in the description, and say exactly what it should return.
  - The report comes back only to you, not to the user: pass on what matters.
  - Say whether the agent should create content, analyze, or only research, since it doesn't know the user's intent.
  - If an agent's description says to use it proactively, do so without waiting to be asked.
  - When general-purpose is the only agent, use it for any complex, context-heavy task: it has the same capabilities as you.\
  """

  # A subagent that starts from the parent's conversation reads a request in
  # it to hand work to a subagent as one for itself, so the task says that
  # already happened, and to use what the conversation established.
  @inherited_conversation_note "[The messages above are the conversation so far, which you continue as the subagent " <>
                                 "that was just asked for help. Any request in them to hand work to a subagent already " <>
                                 "happened: you are that subagent. Use the specific facts, figures and identifiers that " <>
                                 "conversation established, rather than answering in general terms. Your task is below.]\n\n"

  # Keys of the parent's state that stay with the parent, both ways. An
  # agent's private keys don't reach its `task` tool at all.
  @child_state_exclusion_names MapSet.new(~w(messages todos structured_response subagent_outputs subagent_cache))

  # A failed resume with these errors means the person's decisions were wrong
  # for the paused subagent: the parent run fails with the error and stays
  # paused, as a direct review does.
  @resume_error_types [:invalid_human_decision, :invalid_resume]

  defstruct subagents: [],
            model: nil,
            backend: State.new(),
            parent_tools: [],
            permissions: [],
            skills: [],
            interrupt_on: nil,
            summarization: true,
            compact_conversation: true,
            host: nil,
            child_mode: :foreground,
            parent_private_keys: MapSet.new(),
            system_prompt: nil,
            task_description: @task_description

  @doc """
  Builds the middleware. Raises `ArgumentError` when a subagent can't be
  used: an unknown option, a missing name or description, a duplicate name,
  or an invalid `execution_mode`, `capture_output` or `base_middleware`.
  """
  def new(opts \\ []) do
    case build(opts) do
      {:ok, middleware} -> middleware
      {:error, %Error{message: message}} -> raise ArgumentError, message
    end
  end

  @doc false
  # `new/1` that returns an `:invalid_subagent` error instead of raising it,
  # so `BeamWeaver.Agent.build/1` can return it.
  @spec build(keyword()) :: {:ok, struct()} | {:error, Error.t()}
  def build(opts \\ []) do
    host = Keyword.get(opts, :host)

    {profiles, entries} =
      opts
      |> Keyword.get(:subagents, [])
      |> List.wrap()
      |> Enum.split_with(&match?(%GeneralPurposeSubagentProfile{}, &1))

    with {:ok, child_mode} <- child_mode(Keyword.get(opts, :child_mode, :foreground)),
         {:ok, subagents} <-
           entries
           |> maybe_add_general_purpose_subagent(opts, host, merge_general_purpose_profiles(profiles))
           |> normalize_subagents(host),
         :ok <- check_subagents(subagents) do
      {:ok,
       %__MODULE__{
         subagents: subagents,
         model: Keyword.get(opts, :model),
         backend: Keyword.get(opts, :backend, State.new()),
         parent_tools: Keyword.get(opts, :parent_tools, []),
         permissions: Keyword.get(opts, :permissions, []),
         skills: Keyword.get(opts, :skills, []),
         interrupt_on: Keyword.get(opts, :interrupt_on),
         summarization: Keyword.get(opts, :summarization, true),
         compact_conversation: Keyword.get(opts, :compact_conversation, true),
         host: host,
         child_mode: child_mode,
         system_prompt: Keyword.get(opts, :system_prompt),
         task_description: Keyword.get(opts, :task_description) || @task_description
       }}
    end
  end

  @doc false
  # The agent's private and managed keys, which stay the agent's when a
  # subagent hands its state back.
  @spec bind_private_keys([term()], [String.t()]) :: [term()]
  def bind_private_keys(middleware, keys) when is_list(middleware) do
    Enum.map(middleware, fn
      %__MODULE__{} = subagents -> %{subagents | parent_private_keys: MapSet.new(keys, &to_string/1)}
      other -> other
    end)
  end

  @doc false
  # Checks every subagent the way a `task` call builds it, without compiling
  # its graph: an agent checks its subagents when it is built, and a `task`
  # call builds only the subagent it runs. `opts` go to
  # `BeamWeaver.Agent.Compiler.validate/2`.
  @spec validate(struct(), keyword()) :: :ok | {:error, Error.t()}
  def validate(%__MODULE__{subagents: subagents} = middleware, opts \\ []) do
    Enum.find_value(subagents, :ok, fn %Compiled{name: name} = subagent ->
      case validate_subagent(subagent, middleware, opts) do
        :ok -> nil
        {:error, %Error{} = error} -> {:error, invalid_subagent(name, error)}
      end
    end)
  end

  defp validate_subagent(%Compiled{agent: %Spec{} = spec}, middleware, opts) do
    spec
    |> agents_options(subagent_context(spec, middleware))
    |> Enum.find_value(:ok, fn options ->
      with {:ok, agent_spec} <- Builder.validate(options, opts),
           :ok <- check_middleware_nodes(agent_spec) do
        nil
      end
    end)
  rescue
    # Middleware and capability constructors raise for options they can't take.
    error in [ArgumentError, KeyError] -> {:error, Error.new(:invalid_subagent, Exception.message(error))}
  end

  defp validate_subagent(%Compiled{agent: %Built{}}, _middleware, _opts), do: :ok
  defp validate_subagent(%Compiled{agent: :host_managed}, _middleware, _opts), do: :ok

  defp validate_subagent(%Compiled{agent: module}, _middleware, opts) when is_atom(module) do
    cond do
      BeamWeaver.Behaviour.exported?(module, :__beam_weaver_agent_spec__, 0) -> Compiler.validate_module(module, opts)
      graph_module?(module) -> :ok
      true -> {:error, Error.new(:invalid_subagent, "#{inspect(module)} is not an agent or graph module")}
    end
  end

  defp validate_subagent(%Compiled{agent: agent}, _middleware, _opts) do
    {:error,
     Error.new(
       :invalid_subagent,
       "agent must be an agent module or an agent from BeamWeaver.Agent.build/1, got: #{inspect(agent)}"
     )}
  end

  # Two middleware of one name that hook into the same step declare the same
  # node of the agent's graph, which only building the graph would find.
  defp check_middleware_nodes(%AgentSpec{middleware: middleware}) do
    {:ok, middleware} = Middleware.normalize_all(middleware)

    duplicates =
      for hook <- [:before_agent, :before_model, :after_model, :after_agent],
          {name, count} <-
            middleware |> Enum.filter(&Middleware.hook?(&1, hook)) |> Enum.frequencies_by(&Middleware.name/1),
          count > 1,
          do: "#{name}.#{hook}"

    if duplicates == [] do
      :ok
    else
      {:error,
       Error.new(:invalid_graph, "graph contains duplicate declarations: #{Enum.join(duplicates, ", ")}", %{
         duplicates: Enum.map(duplicates, &%{value: &1, kind: :node})
       })}
    end
  end

  @impl true
  def name(_middleware), do: :deepagents_subagents

  @impl true
  def state_schema(%__MODULE__{host: host}) when not is_nil(host), do: %{}
  def state_schema(_middleware), do: SubagentOutputs.state_schema(%SubagentOutputs{})

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

  @impl true
  def wrap_model_call(%__MODULE__{system_prompt: prompt}, %ModelRequest{} = request, handler)
      when prompt in [nil, ""],
      do: handler.(request)

  def wrap_model_call(%__MODULE__{} = middleware, %ModelRequest{} = request, handler) do
    prompt =
      middleware.system_prompt <>
        "\n\nAvailable subagent types:\n\n" <> available_agents(middleware.subagents)

    request
    |> ModelRequest.override(system_message: append_prompt(request.system_message, prompt))
    |> handler.()
  end

  # A parent without a checkpointer fails before it starts when a subagent
  # pauses for review, or a subagent of a subagent at any depth does, as an
  # agent with its own `interrupt_on` does.
  @impl true
  def requires_checkpointer?(%__MODULE__{subagents: subagents, interrupt_on: rules}),
    do: Enum.any?(subagents, &child_requires_checkpointer?(&1, rules, []))

  defp child_requires_checkpointer?(%Compiled{agent: %Spec{} = spec}, parent_rules, visited),
    do: spec_requires_checkpointer?(spec, parent_rules, visited)

  # A built agent's middleware includes the middleware of its own subagents,
  # which looks further down.
  defp child_requires_checkpointer?(%Compiled{agent: %Built{spec: spec}}, _parent_rules, _visited),
    do: middleware_requires_checkpointer?(spec.middleware)

  # `visited` holds the agent modules on the way down, so modules that name
  # each other as subagents are looked at once.
  defp child_requires_checkpointer?(%Compiled{agent: module}, _parent_rules, visited) when is_atom(module) do
    module not in visited and function_exported?(module, :__beam_weaver_agent_spec__, 0) and
      spec_requires_checkpointer?(module.__beam_weaver_agent_spec__(), nil, [module | visited])
  end

  defp child_requires_checkpointer?(_subagent, _parent_rules, _visited), do: false

  defp spec_requires_checkpointer?(spec, parent_rules, visited) do
    rules = review_rules(spec.interrupt_on, parent_rules)

    rules != nil or middleware_requires_checkpointer?(spec.middleware) or
      Enum.any?(List.wrap(spec.subagents), &nested_requires_checkpointer?(&1, rules, visited))
  end

  # An entry of a subagent's own `subagents` list, which takes that
  # subagent's review rules unless it has its own. The general-purpose
  # subagent and async subagents add nothing: they review with those rules
  # or not at all.
  defp nested_requires_checkpointer?(%Compiled{} = subagent, rules, visited),
    do: child_requires_checkpointer?(subagent, rules, visited)

  defp nested_requires_checkpointer?(entry, rules, visited) do
    case Spec.cast(entry) do
      {:ok, spec} -> child_requires_checkpointer?(%Compiled{agent: spec}, rules, visited)
      {:error, _message} -> false
    end
  end

  defp middleware_requires_checkpointer?(middleware) do
    case Middleware.normalize_all(middleware || []) do
      {:ok, middleware} -> Enum.any?(middleware, &Middleware.requires_checkpointer?/1)
      {:error, _error} -> false
    end
  end

  defp maybe_add_general_purpose_subagent(subagents, _opts, host, _profile) when not is_nil(host), do: subagents

  defp maybe_add_general_purpose_subagent(subagents, opts, nil, profile) do
    cond do
      Enum.any?(subagents, &(subagent_name(&1) == "general-purpose")) -> subagents
      profile.enabled == false -> subagents
      true -> [general_purpose_subagent(opts, profile) | subagents]
    end
  end

  defp merge_general_purpose_profiles(profiles) do
    Enum.reduce(profiles, %GeneralPurposeSubagentProfile{}, fn profile, acc ->
      %GeneralPurposeSubagentProfile{
        enabled: if(is_nil(profile.enabled), do: acc.enabled, else: profile.enabled),
        description: profile.description || acc.description,
        system_prompt: profile.system_prompt || acc.system_prompt
      }
    end)
  end

  defp normalize_subagents(entries, host) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, subagents} ->
      case normalize_subagent(entry, host) do
        {:ok, subagent} -> {:cont, {:ok, subagents ++ [subagent]}}
        {:error, message} -> {:halt, {:error, invalid_subagent(subagent_name(entry), message)}}
      end
    end)
  end

  defp normalize_subagent(%Compiled{} = subagent, _host) do
    with {:ok, capture_output} <- capture_output(subagent.capture_output),
         {:ok, execution_mode} <- execution_mode(subagent.execution_mode) do
      {:ok, %{subagent | capture_output: capture_output, execution_mode: execution_mode}}
    end
  end

  # A spec is checked here and built into an agent when a `task` call asks for
  # it, so a parent run doesn't build every subagent, and their subagents.
  defp normalize_subagent(%Spec{} = subagent, nil) do
    with :ok <- check_base_middleware(subagent.base_middleware),
         {:ok, capture_output} <- capture_output(subagent.capture_output),
         {:ok, execution_mode} <- execution_mode(subagent.execution_mode) do
      {:ok,
       %Compiled{
         name: subagent.name,
         description: subagent.description,
         agent: subagent,
         recursion_limit: subagent.recursion_limit,
         inherit_messages: subagent.inherit_messages == true,
         capture_output: capture_output,
         execution_mode: execution_mode
       }}
    end
  end

  defp normalize_subagent(%Spec{} = subagent, _host) do
    with {:ok, execution_mode} <- execution_mode(subagent.execution_mode) do
      {:ok,
       %Compiled{
         name: subagent.name,
         description: subagent.description,
         agent: :host_managed,
         execution_mode: execution_mode
       }}
    end
  end

  defp normalize_subagent(entry, host) do
    with {:ok, spec} <- Spec.cast(entry), do: normalize_subagent(spec, host)
  end

  # An `:invalid_subagent` error that names the subagent, when it has a name.
  defp invalid_subagent(name, %Error{} = error) do
    Error.new(:invalid_subagent, subagent_message(name, error.message), %{subagent: name, error: error})
  end

  defp invalid_subagent(name, message) when is_binary(message),
    do: Error.new(:invalid_subagent, subagent_message(name, message), %{subagent: name})

  defp subagent_message(name, message) do
    if blank?(name), do: message, else: "subagent #{inspect(name)}: #{message}"
  end

  # The general-purpose subagent works as the main agent does: without the
  # tools the main agent excludes, with its tool descriptions, filesystem
  # permissions and capability profile, and with the main agent's own entries
  # for the middleware it would build.
  defp general_purpose_subagent(opts, %GeneralPurposeSubagentProfile{} = profile) do
    capability_profile = Keyword.get(opts, :capability_profile)

    %Spec{
      name: "general-purpose",
      exclude_tools: Keyword.get(opts, :exclude_tools, []),
      tool_descriptions: Keyword.get(opts, :tool_descriptions, %{}),
      capability_profile: capability_profile,
      description:
        profile.description ||
          Keyword.get(opts, :general_purpose_description, @default_general_purpose_description),
      system_prompt:
        profile.system_prompt || Keyword.get(opts, :general_purpose_system_prompt, @default_subagent_prompt),
      base_middleware: [:deepagents],
      middleware: general_purpose_middleware(Keyword.get(opts, :parent_middleware, []), capability_profile)
    }
  end

  # The middleware the general-purpose subagent builds itself: the
  # `:deepagents` capabilities and tool call normalization.
  @general_purpose_modules [Skills, Filesystem, Summarization, CompactConversation, ToolCallNormalization]

  # The main agent's own entries that take the place of middleware the
  # general-purpose subagent would build or get from the profile. The main
  # agent's other middleware is its own.
  defp general_purpose_middleware(parent_middleware, capability_profile) do
    profile_modules = capability_profile |> profile_middleware() |> Enum.map(&middleware_module/1)
    replaced = Enum.reject(@general_purpose_modules ++ profile_modules, &is_nil/1)
    Enum.filter(parent_middleware, &(middleware_module(&1) in replaced))
  end

  defp profile_middleware(%CapabilityProfile{} = profile), do: CapabilityProfile.materialize_extra_middleware(profile)
  defp profile_middleware(_profile), do: []

  defp check_base_middleware(entries) do
    case Enum.find(List.wrap(entries), &is_binary/1) do
      nil -> :ok
      entry -> {:error, "base_middleware entries must use atom or module values, got #{inspect(entry)}"}
    end
  end

  defp subagent_name(%Compiled{name: name}), do: name
  defp subagent_name(%Spec{name: name}), do: name
  defp subagent_name(map) when is_map(map), do: value(map, :name)
  defp subagent_name(opts) when is_list(opts), do: Keyword.get(opts, :name)
  defp subagent_name(_other), do: nil

  # What a spec subagent runs with: its own settings, and the parent's model,
  # tools, files and review rules where it has none.
  defp subagent_context(%Spec{} = subagent, %__MODULE__{} = parent) do
    {:ok, execution_mode} = execution_mode(subagent.execution_mode)

    %{
      model: subagent.model || parent.model,
      model_opts: subagent.model_opts,
      tools: subagent.tools || parent.parent_tools || [],
      backend: subagent_backend(subagent, parent.backend),
      permissions: subagent.permissions || parent.permissions,
      skills: subagent.skills || parent.skills,
      interrupt_on: review_rules(subagent.interrupt_on, parent.interrupt_on),
      summarization: parent.summarization,
      compact_conversation: parent.compact_conversation,
      execution_mode: execution_mode,
      response_format: subagent.response_format
    }
  end

  @doc false
  # The subagent `name` as a `task` call runs it: built with the parent's
  # model, tools and capability settings.
  @spec build_subagent(struct(), String.t()) :: {:ok, Compiled.t()} | {:error, Error.t()}
  def build_subagent(%__MODULE__{subagents: subagents} = middleware, name) do
    case Enum.find(subagents, &(&1.name == name)) do
      %Compiled{} = subagent -> ready_subagent(subagent, middleware)
      nil -> {:error, Error.new(:invalid_subagent, "unknown subagent", %{name: name})}
    end
  end

  defp ready_subagent(%Compiled{agent: %Spec{} = spec} = subagent, %__MODULE__{} = middleware) do
    context = subagent_context(spec, middleware)

    with {:ok, [agent | generate]} <- build_agents(agents_options(spec, context)) do
      {:ok,
       %{
         subagent
         | agent: agent,
           generate_agent: List.first(generate),
           tool_count: length(List.wrap(context.tools)),
           structured_output_strategy: subagent_structured_output_strategy(spec, context)
       }}
    end
  end

  defp ready_subagent(%Compiled{} = subagent, _middleware), do: {:ok, subagent}

  defp build_agents(options) do
    Enum.reduce_while(options, {:ok, []}, fn options, {:ok, agents} ->
      case Builder.build(options) do
        {:ok, agent} -> {:cont, {:ok, agents ++ [agent]}}
        {:error, %Error{}} = error -> {:halt, error}
      end
    end)
  end

  defp subagent_structured_output_strategy(%Spec{response_format: nil}, _context), do: nil

  defp subagent_structured_output_strategy(%Spec{response_format: response_format}, context) do
    tools = if context.execution_mode == :research_then_generate, do: [], else: context.tools

    case response_format |> StructuredOutput.normalize() |> StructuredOutput.effective_strategy(context.model, tools) do
      %ProviderStrategy{} -> :provider
      %ToolStrategy{} -> :tool
      _strategy -> nil
    end
  end

  @research_prompt """
  ## Research Phase
  You are in the RESEARCH phase. Your job is to call any tools you need to gather additional context (e.g., related deals). When done, summarize what you found in your final message.
  If you don't need any additional data, just say 'No additional research needed.'\
  """

  # The `BeamWeaver.Agent.build/1` options of the agents a spec subagent
  # runs: its agent loop, and for `:research_then_generate` the generate pass
  # after it.
  defp agents_options(%Spec{} = subagent, %{execution_mode: :research_then_generate} = context) do
    research = %{context | execution_mode: :agent_loop, response_format: nil}
    [agent_options(subagent, research, "research", @research_prompt), generate_agent_options(subagent, context)]
  end

  defp agents_options(%Spec{} = subagent, context), do: [agent_options(subagent, context, nil, nil)]

  # The subagent runs with every declaration of its spec, plus the inherited
  # model, tools and review rules and the `base_middleware` capabilities.
  defp agent_options(%Spec{} = subagent, context, name_suffix, prompt_suffix) do
    name =
      ["deepagents.subagent.#{subagent.name}", name_suffix]
      |> Enum.reject(&blank?/1)
      |> Enum.join(".")

    system_prompt =
      [subagent.system_prompt, prompt_suffix]
      |> Enum.reject(&blank?/1)
      |> Enum.join("\n\n")

    subagent
    |> Spec.agent_options()
    |> Map.merge(%{
      name: name,
      model: context.model,
      tools: context.tools,
      middleware: subagent_middleware(subagent, context),
      system_prompt: system_prompt,
      response_format: context.response_format,
      interrupt_on: context.interrupt_on
    })
    |> MapShape.reject_nil_values()
  end

  # The generate pass of `:research_then_generate` is one structured model
  # call: no tools, capabilities or review, only the subagent's middleware.
  defp generate_agent_options(%Spec{} = subagent, context) do
    MapShape.reject_nil_values(%{
      name: "deepagents.subagent.#{subagent.name}.generate",
      model: context.model,
      model_opts: subagent.model_opts,
      middleware: subagent_middleware(%{subagent | base_middleware: []}, %{context | execution_mode: :structured_once}),
      system_prompt: subagent.system_prompt,
      response_format: context.response_format,
      context_schema: subagent.context_schema,
      checkpointer: subagent.checkpointer,
      store: subagent.store
    })
  end

  # A subagent's own review rules win, and `false` or an empty map turns
  # review off; without rules of its own it takes the parent's.
  defp review_rules(nil, parent_rules), do: enabled_review_rules(parent_rules)
  defp review_rules(rules, _parent_rules), do: enabled_review_rules(rules)

  defp enabled_review_rules(rules) when rules in [nil, false, []] or rules == %{}, do: nil
  defp enabled_review_rules(rules), do: rules

  defp check_subagents([]) do
    {:error, Error.new(:invalid_subagent, "no subagents: declare one, or keep the general-purpose subagent enabled")}
  end

  defp check_subagents(subagents) do
    duplicates = for {name, count} <- Enum.frequencies_by(subagents, & &1.name), count > 1, do: name

    if duplicates == [] do
      Enum.find_value(subagents, :ok, &check_subagent_fields/1)
    else
      {:error,
       Error.new(:invalid_subagent, "duplicate subagent names: #{Enum.join(duplicates, ", ")}", %{
         subagents: duplicates
       })}
    end
  end

  defp check_subagent_fields(%Compiled{name: name, description: description, agent: agent}) do
    cond do
      blank?(name) -> {:error, Error.new(:invalid_subagent, "subagent name is required")}
      blank?(description) -> {:error, invalid_subagent(name, "description is required")}
      is_nil(agent) -> {:error, invalid_subagent(name, "agent is required")}
      true -> nil
    end
  end

  defp subagent_trace_tools(%__MODULE__{subagents: subagents}) do
    Enum.map(subagents, fn %Compiled{} = subagent ->
      %{
        name: "run_#{subagent.name}",
        description: "Run the #{subagent.name} subagent with verification. #{subagent.description}",
        input_schema: %{
          "type" => "object",
          "properties" => %{},
          "additionalProperties" => false
        },
        strict: true
      }
    end)
  end

  defp run_task(%__MODULE__{subagents: subagents} = middleware, input) do
    name = value(input, :subagent_type) || value(input, :subagent_name) || value(input, :name)
    description = value(input, :description, "")

    case Enum.find(subagents, &(&1.name == name)) do
      nil -> unknown_subagent(name, subagents)
      %Compiled{} when not is_nil(middleware.host) -> run_host_task(middleware, name, description, input)
      %Compiled{} = subagent -> run_subagent_task(middleware, subagent, description, input)
    end
  end

  defp run_subagent_task(middleware, subagent, description, input) do
    parent_state = value(input, :state, %{}) || %{}
    input_hash = input_hash(description)

    case capture_cache(parent_state, subagent.capture_output, subagent.name, input_hash) do
      {:hit, output} ->
        cached_task_output(input, output, subagent, input_hash)

      :miss ->
        with {:ok, subagent} <- ready_subagent(subagent, middleware),
             {:ok, state} <- run_subagent(subagent, parent_state, description, input) do
          task_output(input, parent_state, without_parent_private_keys(state, middleware), subagent, input_hash)
        else
          # The tools node pauses the parent run with the subagent's
          # interrupt, or fails it when the decisions didn't fit.
          :review_cancelled -> cancelled_review(input)
          {:interrupted, interrupt} -> throw({:beam_weaver_graph_interrupt, interrupt})
          {:resume_error, %Error{} = error} -> throw({:beam_weaver_graph_error, error})
          {:error, %Error{} = error} -> format_subagent_error(error)
        end
    end
  end

  # A message to the parent while the subagent's review waits cancels the
  # review, as it does for the parent's own tools.
  defp cancelled_review(input) do
    answer = Prompt.cancelled_review_answer(%{id: value(input, :tool_call_id), name: "task"})
    %Command{update: %{messages: [answer]}}
  end

  defp review_cancelled?(input) do
    case AgentState.messages(value(input, :state, %{}) || %{}) do
      messages when is_list(messages) ->
        id = value(input, :tool_call_id)
        Prompt.message_after_turn?(messages, Enum.find(messages, &Prompt.makes_call?(&1, id)))

      _other ->
        false
    end
  end

  # A key the parent keeps private stays the parent's: the subagent's value
  # of it doesn't come back.
  defp without_parent_private_keys(state, %__MODULE__{parent_private_keys: keys}),
    do: Map.reject(state, fn {key, _value} -> MapSet.member?(keys, to_string(key)) end)

  defp run_host_task(middleware, name, description, input) do
    proposal = %Proposal{
      type: name,
      task: to_string(description),
      mode: middleware.child_mode,
      correlation_id: to_string(value(input, :tool_call_id, ""))
    }

    context = value(input, :runtime) || value(input, :tool_runtime)

    with :ok <- validate_proposal(proposal),
         {:ok, handle} <- Host.admit(middleware.host, proposal, context) do
      host_response(input, Host.result(middleware.host, handle, context))
    else
      error -> host_response(input, error)
    end
  end

  defp host_response(input, {:pending, handle}) do
    host_message(input, "Child admitted as #{handle.id}", %{
      outcome: :pending,
      child_handle_id: handle.id,
      child_mode: handle.mode
    })
  end

  defp host_response(input, {:ok, result}) do
    host_message(input, result.content || Atom.to_string(result.outcome), %{
      outcome: result.outcome,
      child_handle_id: result.handle_id,
      evidence_refs: result.evidence_refs
    })
  end

  defp host_response(_input, {:error, %Error{} = error}), do: format_subagent_error(error)

  defp host_response(_input, {:error, reason}) do
    format_subagent_error(Error.new(:subagent_host_error, "child host failed", %{reason: inspect(reason)}))
  end

  defp host_message(input, content, metadata) do
    message =
      Message.tool(content,
        tool_call_id: value(input, :tool_call_id),
        name: "task",
        metadata: metadata
      )

    {:ok, %Command{update: %{messages: [message]}}}
  end

  defp validate_proposal(%Proposal{} = proposal) do
    if Proposal.valid?(proposal),
      do: :ok,
      else: {:error, Error.new(:invalid_subagent_proposal, "child proposal requires type, task, and correlation id")}
  end

  defp unknown_subagent(name, subagents) do
    allowed = Enum.map_join(subagents, ", ", &"`#{&1.name}`")
    "We cannot invoke subagent #{name} because it does not exist, the only allowed types are #{allowed}"
  end

  defp child_mode(mode) when mode in [:foreground, :background], do: {:ok, mode}
  defp child_mode(mode), do: {:error, Error.new(:invalid_subagent, "invalid child_mode #{inspect(mode)}")}

  defp run_subagent(%Compiled{agent: agent} = subagent, parent_state, description, input)
       when subagent.execution_mode != :research_then_generate or is_nil(subagent.generate_agent) do
    run_child(subagent, agent, child_state(parent_state, description, subagent), input, nil)
  end

  defp run_subagent(
         %Compiled{execution_mode: :research_then_generate, agent: research_agent, generate_agent: generate_agent} =
           subagent,
         parent_state,
         description,
         input
       ) do
    with {:ok, research_state} <-
           run_child(subagent, research_agent, child_state(parent_state, description, subagent), input, "research") do
      generate_description = research_then_generate_description(description, subagent_result(research_state))
      generate_input = child_state(parent_state, generate_description, %{subagent | inherit_messages: false})

      with {:ok, generate_state} <- run_child(subagent, generate_agent, generate_input, input, "generate") do
        {:ok, Map.merge(research_state, generate_state)}
      end
    end
  end

  # One subagent run lives in the parent's thread under a namespace made from
  # the `task` call, so a step that runs again finds it: a paused run resumes
  # when the parent resumes its interrupt, a finished run returns its answer
  # without running again, and an unfinished one continues.
  defp run_child(%Compiled{} = subagent, agent, child_input, input, phase) do
    runtime = runtime_from_input(input)
    agent = with_parent_adapters(agent, runtime)
    opts = child_invoke_opts(agent, runtime, input, subagent, phase)
    stream_metadata = %{subagent_name: subagent.name, tool_call_id: value(input, :tool_call_id)}

    case child_status(agent, opts) do
      :new ->
        child_input = without_child_private_keys(child_input, agent)
        with_child_stream(runtime, stream_metadata, &child_invoke(agent, child_input, opts ++ &1))

      {:unfinished, config} ->
        with_child_stream(runtime, stream_metadata, &child_invoke(agent, %{}, Keyword.put(opts, :config, config) ++ &1))

      {:finished, values} ->
        {:ok, values}

      {:paused, _interrupt} = paused ->
        if review_cancelled?(input),
          do: :review_cancelled,
          else: resume_child(paused, agent, opts, runtime, stream_metadata)
    end
    |> case do
      {:interrupted, interrupt} -> {:interrupted, parent_interrupt(interrupt, stream_metadata)}
      other -> other
    end
  end

  defp resume_child({:paused, interrupt}, agent, opts, runtime, stream_metadata) do
    case resume_value(runtime, interrupt) do
      {:ok, resume} ->
        runtime
        |> with_child_stream(stream_metadata, &child_resume(agent, resume, opts ++ &1))
        |> resume_result()

      :none ->
        {:interrupted, interrupt}
    end
  end

  # The parent's state reaches the `task` tool without the parent's private
  # and managed keys. A key the subagent itself keeps private, managed or
  # internal starts fresh too, so its middleware counts its own run.
  defp without_child_private_keys(child_input, agent) do
    case child_graph(agent) do
      %StateGraph{} = graph -> ChannelLookup.public_state(graph, child_input)
      _other -> child_input
    end
  end

  defp child_graph(%Built{compiled: %{graph: graph}}), do: graph

  defp child_graph(module) do
    case module.graph() do
      %{graph: %StateGraph{} = graph} -> graph
      graph -> graph
    end
  end

  defp resume_result({:error, %Error{type: type} = error}) when type in @resume_error_types,
    do: {:resume_error, error}

  defp resume_result(result), do: result

  # The parent's interrupt carries the subagent's review, so `resume_review/2`
  # on the parent answers it, and its id, which a resumed step matches to the
  # paused subagent. It lists every pause the subagent waits on in
  # `interrupts`, as a subgraph's pause does, each with the subagent's
  # metadata, so a map keyed by their ids answers them all.
  defp parent_interrupt(interrupt, metadata) do
    interrupt
    |> child_interrupt(metadata)
    |> Map.merge(%{
      task_id: nil,
      resumes: [],
      interrupts: interrupt |> Replay.task_interrupts() |> Enum.map(&child_interrupt(&1, metadata))
    })
  end

  defp child_interrupt(interrupt, metadata) do
    %{
      id: value(interrupt, :id),
      value: value(interrupt, :value),
      response_schema: value(interrupt, :response_schema),
      metadata: Map.merge(metadata, value(interrupt, :metadata) || %{})
    }
  end

  defp child_status(agent, opts) do
    with checkpointer when not is_nil(checkpointer) <- Keyword.get(opts, :checkpointer),
         thread_id when thread_id not in [nil, ""] <- get_in(opts, [:config, "configurable", "thread_id"]),
         {:ok, snapshot} <- child_snapshot(agent, opts) do
      cond do
        snapshot.interrupts != [] -> {:paused, paused_interrupt(snapshot)}
        snapshot.next == [] -> {:finished, snapshot.values}
        true -> {:unfinished, snapshot.config}
      end
    else
      _new -> :new
    end
  end

  # A paused subagent's interrupt as its run returned it: the first pause it
  # saved, with every pause it waits on.
  defp paused_interrupt(snapshot) do
    first =
      Enum.find_value(snapshot.pending_writes, hd(snapshot.interrupts), fn
        {_task_id, "__interrupt__", interrupt} -> interrupt |> List.wrap() |> List.first()
        _other -> nil
      end)

    %{
      id: value(first, :id),
      value: value(first, :value),
      response_schema: value(first, :response_schema),
      metadata: value(first, :metadata),
      interrupts: snapshot.interrupts
    }
  end

  defp child_snapshot(%Built{compiled: compiled}, opts),
    do: Graph.Compiled.get_state(compiled, Keyword.fetch!(opts, :config))

  defp child_snapshot(agent, opts) do
    if graph_module?(agent), do: agent.get_state(opts), else: Agent.get_state(agent, opts)
  end

  # A graph module runs with its own functions, an agent with `BeamWeaver.Agent`.
  defp child_invoke(agent, input, opts) do
    if graph_module?(agent), do: agent.invoke(input, opts), else: Agent.invoke(agent, input, opts)
  end

  defp child_resume(agent, resume, opts) do
    if graph_module?(agent), do: agent.resume(resume, opts), else: Agent.resume(agent, resume, opts)
  end

  defp graph_module?(agent) do
    is_atom(agent) and not BeamWeaver.Behaviour.exported?(agent, :__beam_weaver_agent_spec__, 0) and
      BeamWeaver.Behaviour.implemented_by?(agent, BeamWeaver.Graph)
  end

  # A resumed step reruns every `task` call. The resume value belongs to the
  # subagent whose interrupt the parent paused with; other paused subagents
  # pause the parent again, one review at a time.
  defp resume_value(runtime, interrupt) do
    with %{resume_values: [_ | _] = resumes} <- value(runtime, :scratchpad),
         ids = parent_interrupt_ids(runtime),
         true <- Enum.any?(interrupt.interrupts, &(value(&1, :id) in ids)) do
      {:ok, List.last(resumes)}
    else
      _other -> :none
    end
  end

  defp parent_interrupt_ids(runtime) do
    case value(runtime, :checkpointer) do
      nil ->
        []

      checkpointer ->
        %{checkpointer: checkpointer}
        |> Replay.pending_interrupt_records(value(runtime, :config, %{}))
        |> Enum.map(&value(&1, :id))
    end
  end

  # Like a subgraph, the subagent uses the parent's checkpointer and store
  # unless it has its own.
  defp with_parent_adapters(%Built{compiled: compiled} = agent, runtime) do
    compiled = %{
      compiled
      | checkpointer: compiled.checkpointer || value(runtime, :checkpointer),
        store: compiled.store || value(runtime, :store)
    }

    %{agent | compiled: compiled}
  end

  defp with_parent_adapters(agent, _runtime), do: agent

  # A streamed parent run, live or collected (both read the same sink), gets
  # the subagent's events in its stream as they happen.
  defp with_child_stream(runtime, metadata, run) do
    case value(runtime, :stream_sink) do
      %Sink{} = sink -> run.(stream_sink: Sink.child(sink, metadata: metadata), stream_mode: :events)
      _none -> run.([])
    end
  end

  defp research_then_generate_description(description, research_result) do
    text = String.trim(research_result)

    if text != "" and not String.contains?(String.downcase(text), "no additional research needed") do
      """
      #{description}

      ## Additional Research Context
      #{research_result}
      """
    else
      description
    end
  end

  # Every subagent gets tool call normalization, and a `:structured_once` one
  # a one-call limit. An entry of its own middleware replaces the
  # `base_middleware` or implied entry of the same module, such as its own
  # `Skills` or `ModelCallLimit`, as an agent's own entry replaces a
  # capability's, and runs where it is in its own list.
  defp subagent_middleware(subagent, context) do
    own = subagent.middleware |> List.wrap() |> List.flatten() |> Enum.reject(&is_nil/1)
    own_modules = own |> Enum.map(&middleware_module/1) |> Enum.reject(&is_nil/1)

    [
      subagent.base_middleware |> List.wrap() |> Enum.flat_map(&base_middleware_entry(&1, context)),
      ToolCallNormalization.new(),
      maybe_model_call_limit(context.execution_mode)
    ]
    |> List.flatten()
    |> Enum.reject(&(is_nil(&1) or middleware_module(&1) in own_modules))
    |> Kernel.++(own)
  end

  defp middleware_module(%module{}), do: module
  defp middleware_module({module, _opts}) when is_atom(module), do: module
  defp middleware_module(module) when is_atom(module), do: module
  defp middleware_module(_entry), do: nil

  defp base_middleware_entry(:deepagents, context) do
    [
      maybe_skills(context.backend, context.skills),
      filesystem_middleware(context.backend, context.permissions),
      maybe_summarization(context, context.summarization),
      maybe_compact_conversation(
        context.model,
        context.backend || State.new(),
        context.summarization,
        context.compact_conversation
      )
    ]
  end

  defp base_middleware_entry({TodoList, opts}, _context), do: [TodoList.new(opts)]
  defp base_middleware_entry(TodoList, _context), do: [TodoList.new()]

  defp base_middleware_entry({Filesystem, opts}, context) do
    [
      filesystem_middleware(
        Keyword.get(opts, :backend, context.backend),
        Keyword.get(opts, :permissions, context.permissions)
      )
    ]
  end

  defp base_middleware_entry(Filesystem, context),
    do: [filesystem_middleware(context.backend, context.permissions)]

  defp base_middleware_entry({Skills, opts}, context),
    do: [maybe_skills(Keyword.get(opts, :backend, context.backend), Keyword.get(opts, :skills, context.skills))]

  defp base_middleware_entry(Skills, context), do: [maybe_skills(context.backend, context.skills)]

  defp base_middleware_entry({Summarization, opts}, context),
    do: [maybe_summarization(context, opts)]

  defp base_middleware_entry(Summarization, context),
    do: [maybe_summarization(context, context.summarization)]

  defp base_middleware_entry({CompactConversation, opts}, context),
    do: [maybe_compact_conversation(context.model, context.backend || State.new(), context.summarization || true, opts)]

  defp base_middleware_entry(CompactConversation, context) do
    [
      maybe_compact_conversation(
        context.model,
        context.backend || State.new(),
        context.summarization || true,
        context.compact_conversation
      )
    ]
  end

  defp base_middleware_entry(value, _context), do: [value]

  defp filesystem_middleware(nil, _permissions), do: nil

  defp filesystem_middleware(backend, permissions),
    do: Filesystem.new(backend: backend, permissions: permissions || [])

  defp maybe_model_call_limit(:structured_once), do: ModelCallLimit.new(run_limit: 1)
  defp maybe_model_call_limit(_execution_mode), do: nil

  defp subagent_backend(%Spec{filesystem: nil}, parent_backend), do: parent_backend
  defp subagent_backend(%Spec{filesystem: backend}, _parent_backend), do: backend

  defp execution_mode(nil), do: {:ok, :agent_loop}

  defp execution_mode(mode) when mode in [:agent_loop, :structured_once, :research_then_generate],
    do: {:ok, mode}

  defp execution_mode(mode) do
    {:error,
     "unknown subagent execution_mode #{inspect(mode)}; expected :agent_loop, :structured_once, or :research_then_generate"}
  end

  defp capture_output(value) when value in [nil, false], do: {:ok, nil}

  # Already normalized, as in a compiled subagent built by this middleware.
  defp capture_output(%{key: key, dedupe: _dedupe, parent_result: _result} = capture) when is_binary(key),
    do: {:ok, capture}

  defp capture_output(value) when is_atom(value), do: capture_config(value, [])
  defp capture_output({key, opts}) when is_list(opts) or is_map(opts), do: capture_config(key, opts)

  defp capture_output(opts) when is_list(opts) or is_map(opts),
    do: capture_config(option_value(opts, :key) || option_value(opts, :capture_key), opts)

  defp capture_output(value), do: {:error, "invalid capture_output #{inspect(value)}"}

  defp capture_config(nil, _opts), do: {:error, "capture_output requires a key"}

  defp capture_config(key, _opts) when not is_atom(key),
    do: {:error, "capture_output key must be an atom, got #{inspect(key)}"}

  defp capture_config(key, opts) do
    with {:ok, parent_result} <- parent_result(option_value(opts, :parent_result, :ack)) do
      {:ok, %{key: to_string(key), dedupe: option_value(opts, :dedupe, true) != false, parent_result: parent_result}}
    end
  end

  defp parent_result(:full), do: {:ok, :full}
  defp parent_result(value) when value in [nil, :ack], do: {:ok, :ack}

  defp parent_result(value),
    do: {:error, "invalid capture_output parent_result #{inspect(value)}; expected :ack or :full"}

  defp option_value(opts, key, default \\ nil)
  defp option_value(opts, key, default) when is_list(opts), do: Keyword.get(opts, key, default)
  defp option_value(opts, key, default), do: Map.get(opts, key, default)

  defp maybe_skills(_backend, skills) when skills in [nil, []], do: nil
  defp maybe_skills(nil, _skills), do: nil
  defp maybe_skills(backend, skills), do: Skills.new(backend: backend, skills: skills)

  defp maybe_summarization(_context, summarization) when summarization in [nil, false], do: nil

  # Fractional limits are taken of the subagent's model's context window, and
  # a summary covers all the old messages, as an agent's own does.
  defp maybe_summarization(context, settings) when is_list(settings) do
    settings
    |> Keyword.put_new(:model, context.model)
    |> Keyword.put_new(:trim_tokens_to_summarize, nil)
    |> Keyword.put_new_lazy(:max_input_tokens, fn -> context_window(context.model, context.model_opts) end)
    |> Summarization.new()
  end

  defp maybe_summarization(context, _enabled), do: maybe_summarization(context, [])

  # A "provider:model" string is resolved as the subagent's agent resolves
  # it, with its model options, only to read its profile.
  defp context_window(model, opts) when is_binary(model) or (is_atom(model) and not is_nil(model)) do
    with true <- Keyword.keyword?(opts),
         opts = ProviderProfile.apply_provider_profile(to_string(model), opts, run_pre_init: false),
         {:ok, resolved} <- ModelResolver.resolve_agent_model(model, opts) do
      Capabilities.max_input_tokens(resolved)
    else
      _unresolved -> nil
    end
  end

  defp context_window(model, _opts), do: Capabilities.max_input_tokens(model)

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

  defp child_state(parent_state, description, %Compiled{} = subagent) when is_map(parent_state) do
    inherited =
      if subagent.inherit_messages == true,
        do: parent_state |> Map.get(:messages) |> List.wrap() |> Enum.filter(&stable_parent_message?/1),
        else: []

    parent_state
    |> Map.reject(fn {key, _value} -> child_state_excluded_key?(key) end)
    |> Map.put(:messages, inherited ++ [task_message(inherited, description)])
  end

  defp child_state(_parent_state, description, _subagent), do: %{messages: [Message.user(description)]}

  defp task_message([], description), do: Message.user(description)
  defp task_message(_inherited, description), do: Message.user(@inherited_conversation_note <> to_string(description))

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

  defp task_output(input, parent_state, child_state, %Compiled{capture_output: nil} = subagent, _input_hash) do
    merge = child_state_update(parent_state, child_state)
    emit_task_result(input, merge, subagent_result(child_state), subagent, false, nil)
  end

  defp task_output(input, parent_state, child_state, %Compiled{capture_output: capture} = subagent, input_hash) do
    captured = child_state |> captured_result(subagent_result(child_state)) |> json_safe_value()

    merge =
      parent_state
      |> child_state_update(child_state)
      |> Map.merge(%{
        subagent_outputs: %{capture.key => captured},
        subagent_cache: capture_cache_update(capture, cache_key(subagent.name, input_hash), captured)
      })

    emit_task_result(input, merge, capture_content(capture, subagent, captured, false), subagent, false, input_hash)
  end

  defp cached_task_output(input, output, %Compiled{capture_output: capture} = subagent, input_hash) do
    merge = %{subagent_outputs: %{capture.key => output}}
    emit_task_result(input, merge, capture_content(capture, subagent, output, true), subagent, true, input_hash)
  end

  defp emit_task_result(input, merge, result, %Compiled{} = subagent, cached?, input_hash) do
    tool_call_id = value(input, :tool_call_id)

    if is_binary(tool_call_id) and tool_call_id != "" do
      message =
        Message.tool(result,
          tool_call_id: tool_call_id,
          name: "task",
          metadata: task_result_metadata(subagent, cached?, input_hash)
        )

      %Command{update: Map.put(merge, :messages, [message])}
    else
      result
    end
  end

  defp child_invoke_opts(agent, runtime, input, %Compiled{} = subagent, phase) do
    checkpointer = agent_checkpointer(agent, runtime)

    config =
      runtime
      |> child_config(input, subagent.name, phase)
      |> maybe_put_child_thread(checkpointer, runtime)

    []
    |> MapShape.put_present(:context, value(runtime, :context))
    |> Keyword.put(:config, config)
    |> Keyword.put(:trace, subagent_trace(subagent, phase))
    |> MapShape.put_present(:checkpointer, checkpointer)
    |> MapShape.put_present(:store, agent_store(agent, runtime))
    |> MapShape.put_present(:recursion_limit, child_recursion_limit(subagent, agent, runtime))
  end

  # A subagent saves its checkpoints in the parent's thread. When the parent
  # run has none, because only the subagent has a checkpointer, it saves in
  # a thread named after the parent run, so two runs never share one.
  defp maybe_put_child_thread(config, nil, _runtime), do: config

  defp maybe_put_child_thread(%{"configurable" => configurable} = config, _checkpointer, runtime) do
    if Map.get(configurable, "thread_id") in [nil, ""] do
      execution = value(runtime, :execution, %{})
      run_id = value(runtime, :run_id) || value(execution, :run_id) || ID.uuidv7()
      put_in(config, ["configurable", "thread_id"], to_string(run_id))
    else
      config
    end
  end

  defp agent_checkpointer(%Built{compiled: compiled}, _runtime), do: compiled.checkpointer
  defp agent_checkpointer(module, runtime), do: module.checkpointer() || value(runtime, :checkpointer)

  defp agent_store(%Built{compiled: compiled}, _runtime), do: compiled.store
  defp agent_store(module, runtime), do: module.store() || value(runtime, :store)

  defp child_recursion_limit(%Compiled{recursion_limit: limit}, _agent, _runtime) when is_integer(limit), do: limit

  defp child_recursion_limit(_subagent, agent, runtime),
    do: declared_recursion_limit(agent) || parent_recursion_limit(runtime)

  defp declared_recursion_limit(%Built{}), do: nil

  defp declared_recursion_limit(module) do
    if graph_module?(module),
      do: ModuleRunner.recursion_limit(module),
      else: module.__beam_weaver_agent_spec__().recursion_limit
  end

  # A node sees the steps its run has left; the parent run's limit is those
  # plus the current step.
  defp parent_recursion_limit(runtime) do
    case {value(runtime, :recursion_limit), value(runtime, :step)} do
      {left, step} when is_integer(left) and is_integer(step) -> left + step
      _other -> nil
    end
  end

  defp task_result_metadata(%Compiled{} = subagent, cached?, input_hash) do
    %{
      integration: :deepagents,
      kind: :subagent_result,
      subagent_name: subagent.name,
      subagent_type: subagent.name,
      execution_mode: subagent.execution_mode,
      structured_output_strategy: subagent.structured_output_strategy,
      cache_hit: cached?
    }
    |> MapShape.put_present(:capture_key, subagent.capture_output && subagent.capture_output.key)
    |> MapShape.put_present(:input_hash, input_hash)
  end

  defp subagent_trace(%Compiled{} = subagent, phase) do
    metadata =
      %{
        subagent_name: subagent.name,
        subagent_type: subagent.name,
        structured_output_strategy: subagent.structured_output_strategy
      }
      |> MapShape.put_present(:subagent_phase, phase)
      |> MapShape.put_present(:capture_key, subagent.capture_output && subagent.capture_output.key)

    [
      name: "deepagents.subagent.#{subagent.name}",
      execution_mode: to_string(subagent.execution_mode),
      metadata: metadata
    ]
  end

  defp capture_cache(parent_state, %{dedupe: dedupe}, subagent_name, input_hash)
       when dedupe != false and is_map(parent_state) do
    case Map.get(state_map(parent_state, :subagent_cache), cache_key(subagent_name, input_hash)) do
      %{} = entry ->
        case Map.get(entry, "output", Map.get(entry, :output)) do
          nil -> :miss
          output -> {:hit, output}
        end

      # An older entry names the captured output instead of holding it.
      output_key when is_binary(output_key) ->
        case Map.fetch(state_map(parent_state, :subagent_outputs), output_key) do
          {:ok, output} -> {:hit, output}
          :error -> :miss
        end

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

  defp captured_result(child_state, result) when is_map(child_state) do
    case Map.get(child_state, :structured_response) do
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

  defp capture_content(%{parent_result: :full}, _subagent, output, _cached?), do: captured_parent_result(output)

  # What the parent's model reads instead of a captured answer: the task is
  # done, so it shouldn't run it again or guess the answer.
  defp capture_content(%{parent_result: :ack} = capture, %Compiled{name: name}, _output, false),
    do: "The #{name} subagent finished the task. Its answer was saved as \"#{capture.key}\" and is not shown here."

  defp capture_content(%{parent_result: :ack} = capture, %Compiled{name: name}, _output, true),
    do:
      "The #{name} subagent already finished this task. Its saved answer \"#{capture.key}\" was reused and is not shown here."

  defp state_map(state, key) do
    case Map.get(state, key) do
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
    parent_config = Map.new(value(runtime, :config) || %{}, fn {key, value} -> {to_string(key), value} end)
    execution = value(runtime, :execution) || %{}
    configurable = Checkpoint.configurable(parent_config)

    configurable =
      for key <- [:thread_id, :checkpoint_ns, :checkpoint_id],
          Map.get(configurable, Atom.to_string(key)) in [nil, ""],
          reduce: configurable do
        acc -> MapShape.put_present(acc, Atom.to_string(key), MapShape.empty_to_nil(value(execution, key)))
      end

    parent_ns = Map.get(configurable, "checkpoint_ns", "")
    child_ns = child_namespace(parent_ns, runtime, input, subagent_name, phase)
    Map.put(parent_config, "configurable", SubgraphRouter.child_configurable(configurable, parent_ns, child_ns))
  end

  defp child_namespace(parent_ns, runtime, input, subagent_name, phase) do
    parent_ns
    |> Namespace.child(value(runtime, :node, "task"), runtime_task_id(runtime, input))
    |> Namespace.child(subagent_namespace(subagent_name, phase), value(input, :tool_call_id))
    |> Namespace.serialize()
  end

  defp subagent_namespace(subagent_name, nil), do: "subagent.#{subagent_name}"
  defp subagent_namespace(subagent_name, phase), do: "subagent.#{subagent_name}.#{phase}"

  defp runtime_task_id(runtime, input) do
    value(runtime, :task_id) ||
      value(value(runtime, :execution, %{}), :task_id) ||
      value(input, :tool_call_id)
  end

  defp format_subagent_error(%Error{} = error) do
    details =
      if error.details == %{}, do: "", else: " details=#{inspect(error.details, limit: 20, printable_limit: 2_000)}"

    "Subagent error: #{error.message} type=#{inspect(error.type)}" <> details
  end

  defp child_state_update(parent_state, child_state)
       when is_map(parent_state) and is_map(child_state) do
    child_state
    |> Enum.reject(fn {key, value} ->
      child_state_excluded_key?(key) or Map.get(parent_state, key) == value
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
      %Message{role: :assistant} = message -> message |> Message.text() |> MapShape.empty_to_nil()
      _other -> nil
    end) || ""
  end

  defp blank?(value), do: is_nil(value) or String.trim(to_string(value)) == ""

  defp runtime_from_input(input) do
    tool_runtime = value(input, :tool_runtime)
    runtime = value(input, :runtime) || value(tool_runtime, :runtime) || %{}

    for {key, tool_key} <- [
          config: :config,
          context: :context,
          store: :store,
          checkpointer: :checkpointer,
          execution: :execution_info
        ],
        value(runtime, key) in [nil, ""],
        reduce: runtime do
      acc -> MapShape.put_present(acc, key, value(tool_runtime, tool_key))
    end
  end

  defp child_state_excluded_key?(key), do: MapSet.member?(@child_state_exclusion_names, to_string(key))
end
