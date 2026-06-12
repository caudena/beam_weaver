defmodule BeamWeaver.Agent.Capabilities do
  @moduledoc false

  alias BeamWeaver.Agent.Middleware
  alias BeamWeaver.Agent.Middleware.HumanInTheLoop
  alias BeamWeaver.Agent.Middleware.Summarization
  alias BeamWeaver.Agent.Middleware.ToolSelection
  alias BeamWeaver.Agent.ModelResolver
  alias BeamWeaver.Agent.ProviderProfile
  alias BeamWeaver.Agent.Spec
  alias BeamWeaver.Agent.Subagent.AsyncSpec
  alias BeamWeaver.Filesystem.State

  @default_recursion_limit 9999

  @spec apply(Spec.t()) :: Spec.t()
  def apply(%Spec{} = spec) do
    spec
    |> resolve_model()
    |> add_capability_middleware()
    |> maybe_default_recursion_limit()
  end

  defp resolve_model(%Spec{model: model, model_opts: opts} = spec) do
    opts = model_init_opts(model, opts || [])

    case ModelResolver.resolve_model(model, opts) do
      {:ok, resolved} -> %{spec | model: resolved}
      _error -> spec
    end
  end

  defp model_init_opts(model, opts) when is_binary(model) or is_atom(model),
    do: ProviderProfile.apply_provider_profile(to_string(model), opts)

  defp model_init_opts(_model, opts), do: opts

  defp add_capability_middleware(%Spec{} = spec) do
    filesystem = capability_filesystem(spec)
    middleware = List.wrap(spec.middleware || [])

    capability_middleware =
      [
        maybe_skills(spec, filesystem),
        maybe_filesystem(spec, filesystem),
        maybe_subagents(spec, filesystem),
        maybe_summarization(spec),
        maybe_compact_conversation(spec, filesystem),
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

    capability_middleware =
      Enum.reject(capability_middleware, &middleware_present?(middleware, &1))

    %{spec | middleware: capability_middleware ++ middleware}
  end

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

  defp maybe_subagents(%Spec{subagents: subagents}, _filesystem)
       when subagents in [nil, false, []],
       do: nil

  defp maybe_subagents(%Spec{} = spec, filesystem) do
    subagents = sync_subagents(spec.subagents)

    if subagents == [] do
      nil
    else
      new_middleware("Subagents",
        subagents: subagents,
        model: spec.model,
        backend: filesystem || State.new(),
        parent_tools: List.wrap(spec.tools || []),
        permissions: List.wrap(spec.filesystem_permissions || []),
        skills: List.wrap(spec.skills || []),
        interrupt_on: spec.interrupt_on,
        checkpointer: spec.checkpointer,
        summarization: summarization_enabled?(spec),
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
      new_middleware("AsyncSubagents", subagents: subagents)
    end
  end

  defp sync_subagents(subagents) do
    subagents
    |> List.wrap()
    |> Enum.reject(&async_subagent?/1)
  end

  defp async_subagents(subagents) do
    subagents
    |> List.wrap()
    |> Enum.filter(&async_subagent?/1)
  end

  defp async_subagent?(%AsyncSpec{}), do: true
  defp async_subagent?(_subagent), do: false

  defp new_middleware(name, opts) do
    name
    |> middleware_module()
    |> apply(:new, [opts])
  end

  defp middleware_module(name), do: Module.concat(BeamWeaver.Agent.Middleware, name)

  defp maybe_summarization(%Spec{} = spec) do
    case spec.compact_conversation do
      settings when is_list(settings) ->
        Summarization.new(Keyword.put_new(settings, :model, spec.model))

      value when value in [true, :auto] ->
        Summarization.new(model: spec.model, trigger: {:messages, 20}, keep: {:messages, 8})

      _other ->
        nil
    end
  end

  defp maybe_compact_conversation(%Spec{} = spec, filesystem) do
    case spec.compact_conversation do
      settings when is_list(settings) ->
        settings
        |> Keyword.put_new(:model, spec.model)
        |> Keyword.put_new(:backend, filesystem || State.new())
        |> Middleware.CompactConversation.new()

      value when value in [true, :auto] ->
        Middleware.CompactConversation.new(model: spec.model, backend: filesystem || State.new())

      _other ->
        nil
    end
  end

  defp maybe_overflow_recovery(%Spec{} = spec, filesystem) do
    case spec.overflow_recovery do
      settings when is_list(settings) ->
        settings
        |> Keyword.put_new(:backend, filesystem || State.new())
        |> Keyword.put_new(:keep, {:messages, 8})
        |> Keyword.put_new(:max_input_tokens, max_input_tokens(spec.model))
        |> Middleware.OverflowRecovery.new()

      value when value in [true, :auto] ->
        Middleware.OverflowRecovery.new(
          backend: filesystem || State.new(),
          keep: {:messages, 8},
          max_input_tokens: max_input_tokens(spec.model)
        )

      _other ->
        nil
    end
  end

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

  defp summarization_enabled?(%Spec{compact_conversation: value}), do: enabled?(value)

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

  defp max_input_tokens(%{profile: %{max_input_tokens: limit}}) when is_integer(limit), do: limit

  defp max_input_tokens(%{profile: %{"max_input_tokens" => limit}}) when is_integer(limit),
    do: limit

  defp max_input_tokens(_model), do: nil
end
