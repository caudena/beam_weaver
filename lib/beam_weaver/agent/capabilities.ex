defmodule BeamWeaver.Agent.Capabilities do
  @moduledoc false

  alias BeamWeaver.Agent.CapabilityProfile
  alias BeamWeaver.Agent.CapabilityProfileConfig
  alias BeamWeaver.Agent.Middleware
  alias BeamWeaver.Agent.Middleware.DynamicPrompt
  alias BeamWeaver.Agent.Middleware.Helpers
  alias BeamWeaver.Agent.Middleware.HumanInTheLoop
  alias BeamWeaver.Agent.Middleware.Summarization
  alias BeamWeaver.Agent.Middleware.ToolSelection
  alias BeamWeaver.Agent.ModelResolver
  alias BeamWeaver.Agent.ProviderProfile
  alias BeamWeaver.Agent.Spec
  alias BeamWeaver.Agent.Subagent.AsyncSpec
  alias BeamWeaver.Agent.Subagent.Spec, as: SubagentSpec
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Filesystem.State

  @default_recursion_limit 9999

  # Middleware that read and write files: an entry you list yourself uses the
  # declared filesystem unless its own options name a backend.
  @backend_middleware [
    Middleware.Filesystem,
    Middleware.Skills,
    Middleware.Memory,
    Middleware.CompactConversation,
    Middleware.OverflowRecovery
  ]

  @spec apply(Spec.t()) :: {:ok, Spec.t()} | {:error, Error.t()}
  def apply(%Spec{} = spec) do
    with {:ok, profile} <- capability_profile(spec),
         {:ok, spec} <- resolve_model(spec),
         spec = apply_profile(spec, profile),
         filesystem = capability_filesystem(spec),
         {:ok, subagents} <- maybe_subagents(spec, filesystem) do
      {:ok,
       spec
       |> add_capability_middleware(filesystem, subagents)
       |> maybe_default_recursion_limit()}
    end
  rescue
    # The middleware constructors raise for settings they can't take.
    error in [ArgumentError, KeyError] -> {:error, Error.new(:invalid_agent, Middleware.option_error(error))}
  end

  defp resolve_model(%Spec{model: model, model_opts: opts} = spec) do
    cond do
      not Keyword.keyword?(opts) ->
        invalid_model_opts(opts)

      Keyword.has_key?(opts, :tool_timeout) ->
        {:error,
         Error.new(
           :invalid_agent,
           "tool_timeout is not a model option; declare `tool_timeout` in the agent (or pass :tool_timeout to build/1)",
           %{option: :tool_timeout}
         )}

      is_nil(model) ->
        {:ok, spec}

      true ->
        with {:ok, resolved} <- ModelResolver.resolve_agent_model(model, model_init_opts(model, opts)) do
          {:ok, %{spec | model: resolved}}
        end
    end
  end

  defp invalid_model_opts(opts) do
    {:error,
     Error.new(:invalid_agent, "agent model options must be a keyword list", %{
       model_opts: ModelResolver.describe(opts)
     })}
  end

  defp model_init_opts(model, opts) when is_binary(model) or is_atom(model),
    do: ProviderProfile.apply_provider_profile(to_string(model), opts)

  defp model_init_opts(_model, opts), do: opts

  # The profile is looked up before the model is resolved, so `:auto` matches
  # the "provider:model" string as written.
  defp capability_profile(%Spec{capability_profile: value}) when value in [nil, false], do: {:ok, nil}
  defp capability_profile(%Spec{capability_profile: :auto, model: model}), do: {:ok, CapabilityProfile.for_model(model)}
  defp capability_profile(%Spec{capability_profile: %CapabilityProfile{} = profile}), do: {:ok, profile}

  defp capability_profile(%Spec{capability_profile: %CapabilityProfileConfig{} = config}),
    do: {:ok, CapabilityProfileConfig.to_capability_profile(config)}

  defp capability_profile(%Spec{capability_profile: other}) do
    {:error,
     Error.new(
       :invalid_agent,
       "capability_profile must be :auto, a BeamWeaver.Agent.CapabilityProfile or a BeamWeaver.Agent.CapabilityProfileConfig",
       %{capability_profile: inspect(other)}
     )}
  end

  # A profile tunes the agent's own declarations: its prompt text goes after
  # the system prompt, its excluded tools and descriptions join
  # `exclude_tools` and `tool_descriptions` (the agent's own descriptions win),
  # and its middleware follows the agent's.
  defp apply_profile(%Spec{} = spec, nil), do: spec

  defp apply_profile(%Spec{} = spec, %CapabilityProfile{} = profile) do
    middleware = List.wrap(spec.middleware || [])
    extra_middleware = CapabilityProfile.materialize_extra_middleware(profile)
    middleware = middleware ++ Enum.reject(extra_middleware, &middleware_present?(middleware, &1))

    %{
      spec
      | system_prompt: spec.system_prompt || profile.base_system_prompt,
        exclude_tools: Enum.uniq(List.wrap(spec.exclude_tools || []) ++ List.wrap(profile.excluded_tools || [])),
        tool_descriptions: Map.merge(Map.new(profile.tool_descriptions || %{}), Map.new(spec.tool_descriptions || %{})),
        middleware: middleware
    }
    |> append_profile_prompt(profile.prompt_suffix)
  end

  # `DynamicPrompt` replaces the declared prompt, so with one the profile's
  # text goes after the prompt it builds, through another `DynamicPrompt`
  # that runs after it.
  defp append_profile_prompt(%Spec{} = spec, suffix) when suffix in [nil, ""], do: spec

  defp append_profile_prompt(%Spec{} = spec, suffix) do
    if Enum.any?(spec.middleware, &(middleware_key(&1) == DynamicPrompt)) do
      suffix_prompt = DynamicPrompt.new(prompt: &Helpers.append_prompt(&1.system_message, suffix))
      %{spec | middleware: spec.middleware ++ [suffix_prompt]}
    else
      %{spec | system_prompt: append_prompt(spec.system_prompt, suffix)}
    end
  end

  defp append_prompt(prompt, suffix) when suffix in [nil, ""], do: prompt
  defp append_prompt(nil, suffix), do: suffix
  defp append_prompt(prompt, suffix) when is_binary(prompt), do: prompt <> "\n\n" <> suffix
  defp append_prompt(prompt, suffix), do: Helpers.append_prompt(prompt, suffix)

  # Capability middleware goes ahead of the agent's own list. `DynamicPrompt`
  # goes first of all: it replaces the declared `system_prompt`, and every
  # middleware after it adds its own sections to that prompt.
  defp add_capability_middleware(%Spec{} = spec, filesystem, subagents) do
    {dynamic_prompts, middleware} =
      spec.middleware
      |> List.wrap()
      |> Enum.split_with(&(middleware_key(&1) == DynamicPrompt))

    middleware = Enum.map(middleware, &with_declared_backend(&1, spec, filesystem))

    capability_middleware =
      [
        maybe_skills(spec, filesystem),
        maybe_filesystem(spec, filesystem),
        subagents,
        # A compaction the model asked for applies before automatic
        # summarization checks the thread.
        maybe_compact_conversation(spec, filesystem),
        maybe_summarization(spec),
        maybe_overflow_recovery(spec, filesystem),
        maybe_tool_call_normalization(spec),
        maybe_async_subagents(spec),
        maybe_tool_filter(spec),
        maybe_prompt_caching(spec),
        maybe_memory(spec, filesystem),
        maybe_hitl(spec)
      ]
      |> List.flatten()
      |> Enum.reject(&is_nil/1)
      |> Enum.reject(&replaced_by_own_entry?(middleware, &1))

    %{spec | middleware: dynamic_prompts ++ capability_middleware ++ middleware}
  end

  # An entry of the agent's own list replaces the capability middleware of the
  # same module, except `ToolSelection`: the one that `exclude_tools` and
  # `tool_descriptions` add filters the tools before the agent's own runs.
  defp replaced_by_own_entry?(_middleware, %ToolSelection{}), do: false
  defp replaced_by_own_entry?(middleware, candidate), do: middleware_present?(middleware, candidate)

  defp with_declared_backend(entry, _spec, nil), do: entry

  defp with_declared_backend(module, spec, filesystem) when module in @backend_middleware,
    do: {module, declared_backend_opts(module, spec, filesystem)}

  defp with_declared_backend({module, opts}, spec, filesystem) when module in @backend_middleware and is_list(opts),
    do: {module, Keyword.merge(declared_backend_opts(module, spec, filesystem), opts)}

  defp with_declared_backend(entry, _spec, _filesystem), do: entry

  defp declared_backend_opts(Middleware.Filesystem, spec, filesystem),
    do: [backend: filesystem, permissions: List.wrap(spec.filesystem_permissions || [])]

  defp declared_backend_opts(_module, _spec, filesystem), do: [backend: filesystem]

  defp capability_filesystem(%Spec{} = spec) do
    cond do
      not empty?(spec.filesystem) -> spec.filesystem
      filesystem_required?(spec) -> State.new()
      true -> nil
    end
  end

  defp filesystem_required?(%Spec{} = spec) do
    not empty?(spec.skills) or not empty?(spec.memory) or
      enabled?(spec.compact_conversation) or enabled?(spec.overflow_recovery)
  end

  defp maybe_filesystem(%Spec{filesystem: filesystem} = spec, resolved_filesystem) do
    if empty?(filesystem) do
      nil
    else
      Middleware.Filesystem.new(
        backend: resolved_filesystem,
        permissions: List.wrap(spec.filesystem_permissions || [])
      )
    end
  end

  defp maybe_skills(%Spec{skills: skills}, _filesystem) when skills in [nil, false, []], do: nil

  defp maybe_skills(%Spec{skills: skills}, filesystem) do
    Middleware.Skills.new(backend: filesystem || State.new(), skills: skills)
  end

  defp maybe_memory(%Spec{memory: memory}, _filesystem) when memory in [nil, false, []], do: nil

  defp maybe_memory(%Spec{memory: true}, filesystem) do
    Middleware.Memory.new(backend: filesystem || State.new())
  end

  defp maybe_memory(%Spec{memory: memory}, filesystem) do
    Middleware.Memory.new(backend: filesystem || State.new(), memory: memory)
  end

  # The `task` middleware for the `subagents` declaration, or an
  # `:invalid_subagent` error naming the subagent that can't be used.
  defp maybe_subagents(%Spec{subagents: subagents}, _filesystem)
       when subagents in [nil, false, []],
       do: {:ok, nil}

  defp maybe_subagents(%Spec{} = spec, filesystem) do
    case sync_subagents(spec.subagents) do
      [] ->
        {:ok, nil}

      subagents ->
        Middleware.Subagents.build(
          subagents: subagents,
          model: spec.model,
          backend: filesystem || State.new(),
          parent_tools: List.wrap(spec.tools || []),
          permissions: List.wrap(spec.filesystem_permissions || []),
          skills: List.wrap(spec.skills || []),
          interrupt_on: spec.interrupt_on,
          summarization: subagent_summarization(spec),
          compact_conversation: enabled?(spec.compact_conversation)
        )
    end
  end

  defp maybe_async_subagents(%Spec{} = spec) do
    subagents =
      spec.async_subagents
      |> List.wrap()
      |> Kernel.++(async_subagents(spec.subagents))

    if subagents == [] do
      nil
    else
      Middleware.AsyncSubagents.new(subagents: subagents)
    end
  end

  # A `subagent` line that led back to an agent module being read left that
  # subagent unread; it is read here, when the agent that lists it is built.
  defp sync_subagents(subagents) do
    subagents
    |> List.wrap()
    |> Enum.reject(&async_subagent?/1)
    |> Enum.map(fn
      %SubagentSpec{} = subagent -> SubagentSpec.read(subagent)
      subagent -> subagent
    end)
  end

  defp async_subagents(subagents) do
    subagents
    |> List.wrap()
    |> Enum.filter(&async_subagent?/1)
  end

  defp async_subagent?(%AsyncSpec{}), do: true
  defp async_subagent?(_subagent), do: false

  # `compact_conversation` also turns on automatic summarization, configured by
  # its `summarization:` option; the other options configure the tool.
  defp maybe_summarization(%Spec{} = spec) do
    if settings = settings(spec.compact_conversation) do
      model = Keyword.get(settings, :model, spec.model)

      case Keyword.get(settings, :summarization, true) do
        false -> nil
        true -> summarization(spec, model, [])
        summarization when is_list(summarization) -> summarization(spec, model, summarization)
      end
    end
  end

  # Fractional limits are taken of the agent model's context window.
  defp summarization(%Spec{} = spec, model, settings) do
    settings
    |> Keyword.put_new(:model, model)
    |> Keyword.put_new(:max_input_tokens, max_input_tokens(spec.model))
    |> Summarization.new()
  end

  defp maybe_compact_conversation(%Spec{} = spec, filesystem) do
    if settings = settings(spec.compact_conversation) do
      settings
      |> Keyword.delete(:summarization)
      |> Keyword.put_new(:model, spec.model)
      |> Keyword.put_new(:backend, filesystem || State.new())
      |> Middleware.CompactConversation.new()
    end
  end

  defp maybe_overflow_recovery(%Spec{} = spec, filesystem) do
    if settings = settings(spec.overflow_recovery) do
      settings
      |> Keyword.put_new(:backend, filesystem || State.new())
      |> Keyword.put_new(:max_input_tokens, max_input_tokens(spec.model))
      |> Middleware.OverflowRecovery.new()
    end
  end

  defp settings(value) when value in [true, :auto], do: []
  defp settings(settings) when is_list(settings), do: settings
  defp settings(_value), do: nil

  defp maybe_prompt_caching(%Spec{prompt_caching: value}) when value in [nil, false], do: nil

  defp maybe_prompt_caching(%Spec{prompt_caching: settings}) when is_list(settings),
    do: Middleware.PromptCaching.new(settings)

  defp maybe_prompt_caching(%Spec{}), do: Middleware.PromptCaching.new()

  defp maybe_tool_filter(%Spec{} = spec) do
    if empty?(spec.exclude_tools) and empty?(spec.tool_descriptions) do
      nil
    else
      ToolSelection.new(
        deny: List.wrap(spec.exclude_tools || []),
        descriptions: spec.tool_descriptions || %{}
      )
    end
  end

  defp maybe_tool_call_normalization(%Spec{} = spec) do
    if any_capability?(spec), do: Middleware.ToolCallNormalization.new()
  end

  defp maybe_hitl(%Spec{interrupt_on: value}) when value in [nil, false], do: nil
  defp maybe_hitl(%Spec{interrupt_on: value}), do: HumanInTheLoop.new(interrupt_on: value)

  defp maybe_default_recursion_limit(%Spec{recursion_limit: nil} = spec) do
    if any_capability?(spec), do: %{spec | recursion_limit: @default_recursion_limit}, else: spec
  end

  defp maybe_default_recursion_limit(spec), do: spec

  defp any_capability?(%Spec{} = spec) do
    Enum.any?(
      [
        spec.filesystem,
        spec.skills,
        spec.memory,
        spec.subagents,
        spec.async_subagents,
        spec.compact_conversation,
        spec.overflow_recovery,
        spec.prompt_caching,
        spec.exclude_tools,
        spec.tool_descriptions,
        spec.tools,
        spec.middleware,
        spec.interrupt_on
      ],
      &(not empty?(&1))
    )
  end

  # The subagents summarize their conversations when the agent does, with the
  # same settings: `compact_conversation true`, or the `summarization:` option
  # of its settings (`false` turns it off). The summary model, the
  # `compact_conversation` `model:`, carries over when there is one; otherwise
  # each subagent summarizes with its own model.
  defp subagent_summarization(%Spec{compact_conversation: value}) when value in [true, :auto], do: true

  defp subagent_summarization(%Spec{compact_conversation: settings}) when is_list(settings) do
    case Keyword.get(settings, :summarization, true) do
      false -> false
      true -> with_summary_model([], settings)
      summarization when is_list(summarization) -> with_summary_model(summarization, settings)
    end
  end

  defp subagent_summarization(%Spec{}), do: false

  defp with_summary_model(summarization, settings) do
    case Keyword.fetch(settings, :model) do
      {:ok, model} -> Keyword.put_new(summarization, :model, model)
      :error when summarization == [] -> true
      :error -> summarization
    end
  end

  defp enabled?(value), do: value not in [nil, false, []]

  defp empty?(value), do: value in [nil, false, []] or value == %{}

  defp middleware_present?(middleware, candidate) do
    candidate_key = middleware_key(candidate)
    Enum.any?(middleware, &(middleware_key(&1) == candidate_key))
  end

  defp middleware_key(%module{}), do: module
  defp middleware_key(module) when is_atom(module), do: module
  defp middleware_key({module, _opts}) when is_atom(module), do: module
  defp middleware_key(other), do: other

  def max_input_tokens(%{profile: %{max_input_tokens: limit}}) when is_integer(limit), do: limit
  def max_input_tokens(%{profile: %{"max_input_tokens" => limit}}) when is_integer(limit), do: limit
  def max_input_tokens(_model), do: nil
end
