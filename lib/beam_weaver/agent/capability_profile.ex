defmodule BeamWeaver.Agent.CapabilityProfile do
  @moduledoc "DeepAgents harness behavior profile."

  alias BeamWeaver.Agent.CapabilityProfileConfig
  alias BeamWeaver.Agent.GeneralPurposeSubagentProfile
  alias BeamWeaver.Agent.ModelResolver
  alias BeamWeaver.Agent.ProfileRegistry

  @registry_key {__MODULE__, :registry}

  @type t :: %__MODULE__{}

  defstruct name: nil,
            base_system_prompt: nil,
            prompt_suffix: nil,
            middleware: [],
            excluded_middleware: [],
            excluded_tools: [],
            tool_descriptions: %{},
            default_subagent?: true,
            general_purpose_subagent: %GeneralPurposeSubagentProfile{}

  def new(opts \\ []) do
    opts = opts |> Map.new() |> normalize_keys()
    gp = normalize_general_purpose(Map.get(opts, :general_purpose_subagent))

    opts
    |> Map.put(:general_purpose_subagent, gp)
    |> maybe_put_default_subagent(gp)
    |> then(&struct(__MODULE__, &1))
  end

  def builtin(nil), do: new(name: :default)
  def builtin(:default), do: new(name: :default)

  def builtin(:anthropic) do
    new(
      name: :anthropic,
      prompt_suffix: "Use tools carefully and keep intermediate artifacts in the filesystem.",
      default_subagent?: true
    )
  end

  def builtin(:anthropic_haiku_4_5), do: builtin("anthropic:claude-haiku-4-5")
  def builtin(:anthropic_sonnet_4_6), do: builtin("anthropic:claude-sonnet-4-6")
  def builtin(:anthropic_opus_4_8), do: builtin("anthropic:claude-opus-4-8")

  def builtin(:anthropic_opus_4_7) do
    builtin("anthropic:claude-opus-4-7")
  end

  def builtin(:openai_codex) do
    builtin("openai:gpt-5.5")
  end

  def builtin(%__MODULE__{} = profile), do: profile

  def builtin(%{__struct__: CapabilityProfileConfig} = config),
    do: CapabilityProfileConfig.to_capability_profile(config)

  def builtin(other) when is_atom(other) or is_binary(other) do
    get_capability_profile(other) || new(name: other)
  end

  @doc "Returns built-in harness profile keys."
  @spec builtin_keys() :: [String.t()]
  def builtin_keys, do: Map.keys(builtin_profiles()) |> Enum.sort()

  @doc "Registers or merges a harness profile under a provider or provider:model key."
  @spec register_capability_profile(String.t() | atom(), __MODULE__.t() | term()) :: :ok
  def register_capability_profile(key, profile) do
    incoming = builtin(profile)

    ProfileRegistry.register(@registry_key, key, incoming, exact_profiles(), &merge/2)
  end

  @doc """
  Looks up a harness profile for a provider or provider:model spec.

  Exact model profiles are layered on top of provider-level profiles.
  Malformed specs return `nil` instead of falling back to the provider half.
  """
  @spec get_capability_profile(String.t() | atom() | nil) :: __MODULE__.t() | nil
  def get_capability_profile(nil), do: nil

  def get_capability_profile(spec) when is_atom(spec) or is_binary(spec) do
    ProfileRegistry.lookup(spec, exact_profiles(), &merge/2)
  end

  @doc "Returns the harness profile that best matches a raw or resolved model."
  @spec for_model(term(), String.t() | nil) :: __MODULE__.t()
  def for_model(model, spec \\ nil)

  def for_model(_model, spec) when is_binary(spec) do
    get_capability_profile(spec) || new(name: :default)
  end

  def for_model(spec, nil) when is_binary(spec),
    do: get_capability_profile(spec) || new(name: :default)

  def for_model(model, nil) do
    identifier = ModelResolver.get_model_identifier(model)
    provider = ModelResolver.get_model_provider(model)

    cond do
      provider && identifier && not String.contains?(identifier, ":") ->
        get_capability_profile("#{provider}:#{identifier}") ||
          get_capability_profile(provider) ||
          new(name: :default)

      identifier && String.contains?(identifier, ":") ->
        get_capability_profile(identifier) || new(name: :default)

      provider ->
        get_capability_profile(provider) || new(name: :default)

      true ->
        new(name: :default)
    end
  end

  @doc "Materializes the profile middleware list, invoking a zero-arity factory if present."
  @spec materialize_extra_middleware(__MODULE__.t()) :: [term()]
  def materialize_extra_middleware(%__MODULE__{middleware: middleware})
      when is_function(middleware, 0),
      do: middleware.() |> List.wrap()

  def materialize_extra_middleware(%__MODULE__{middleware: middleware}),
    do: List.wrap(middleware)

  @doc "Merges two harness profiles with additive Python DeepAgents semantics."
  @spec merge(__MODULE__.t(), __MODULE__.t()) :: __MODULE__.t()
  def merge(%__MODULE__{} = base, %__MODULE__{} = override) do
    gp = merge_general_purpose(base.general_purpose_subagent, override.general_purpose_subagent)

    new(
      name: override.name || base.name,
      base_system_prompt: override.base_system_prompt || base.base_system_prompt,
      prompt_suffix: override.prompt_suffix || base.prompt_suffix,
      middleware: merge_middleware(base.middleware, override.middleware),
      excluded_middleware: union_terms(base.excluded_middleware, override.excluded_middleware),
      excluded_tools: union_terms(base.excluded_tools, override.excluded_tools),
      tool_descriptions: Map.merge(base.tool_descriptions || %{}, override.tool_descriptions || %{}),
      default_subagent?: merged_default_subagent?(base, override, gp),
      general_purpose_subagent: gp
    )
  end

  def to_map(%__MODULE__{} = profile) do
    %{}
    |> ProfileRegistry.maybe_put(:base_system_prompt, profile.base_system_prompt)
    |> ProfileRegistry.maybe_put(:system_prompt_suffix, profile.prompt_suffix)
    |> ProfileRegistry.maybe_put_map(:tool_description_overrides, profile.tool_descriptions)
    |> ProfileRegistry.maybe_put_list(:excluded_tools, profile.excluded_tools)
    |> ProfileRegistry.maybe_put_list(:excluded_middleware, profile.excluded_middleware)
    |> maybe_put_gp(profile.general_purpose_subagent)
  end

  defp normalize_keys(opts) do
    Map.new(opts, fn
      {"name", value} -> {:name, value}
      {"base_system_prompt", value} -> {:base_system_prompt, value}
      {"system_prompt_suffix", value} -> {:prompt_suffix, value}
      {"prompt_suffix", value} -> {:prompt_suffix, value}
      {"extra_middleware", value} -> {:middleware, value}
      {"middleware", value} -> {:middleware, value}
      {"excluded_middleware", value} -> {:excluded_middleware, value}
      {"excluded_tools", value} -> {:excluded_tools, value}
      {"tool_description_overrides", value} -> {:tool_descriptions, value}
      {"tool_descriptions", value} -> {:tool_descriptions, value}
      {"default_subagent?", value} -> {:default_subagent?, value}
      {"general_purpose_subagent", value} -> {:general_purpose_subagent, value}
      {:system_prompt_suffix, value} -> {:prompt_suffix, value}
      {:extra_middleware, value} -> {:middleware, value}
      {:tool_description_overrides, value} -> {:tool_descriptions, value}
      pair -> pair
    end)
  end

  defp builtin_profiles do
    anthropic_universal =
      new(
        name: "anthropic",
        prompt_suffix:
          "<use_parallel_tool_calls>\nWhen tool calls are independent, make them in parallel.\n</use_parallel_tool_calls>\n\n<investigate_before_answering>\nRead relevant files before making codebase claims.\n</investigate_before_answering>\n\n<tool_result_reflection>\nAfter tool results, reflect on quality and choose the next concrete action.\n</tool_result_reflection>"
      )

    anthropic_opus =
      merge(
        anthropic_universal,
        new(
          name: "anthropic:claude-opus",
          prompt_suffix:
            anthropic_universal.prompt_suffix <>
              "\n\n<tool_usage>\nUse tools to observe files, tests, and system output directly.\n</tool_usage>\n\n<subagent_usage>\nUse subagents for isolated multi-step work and fan-out when useful.\n</subagent_usage>"
        )
      )

    codex =
      new(
        name: "openai_codex",
        prompt_suffix:
          "## Codex-Specific Behavior\n\nAct as an autonomous senior engineer: gather context, implement, verify, and finish the task end-to-end when feasible.\n\n## Parallel Tool Use\n\nBatch independent searches and file reads before acting.\n\n## Plan Hygiene\n\nReconcile any TODO or plan items before finishing."
      )

    %{
      "anthropic" => anthropic_universal,
      "anthropic:claude-haiku-4-5" => %{anthropic_universal | name: "anthropic:claude-haiku-4-5"},
      "anthropic:claude-sonnet-4-6" => %{
        anthropic_universal
        | name: "anthropic:claude-sonnet-4-6"
      },
      "anthropic:claude-opus-4-8" => %{anthropic_opus | name: "anthropic:claude-opus-4-8"},
      "anthropic:claude-opus-4-7" => %{anthropic_opus | name: "anthropic:claude-opus-4-7"},
      "openai:gpt-5.5" => %{codex | name: "openai:gpt-5.5"},
      "openai:gpt-5.4" => %{codex | name: "openai:gpt-5.4"},
      "openai:gpt-5.4-mini" => %{codex | name: "openai:gpt-5.4-mini"}
    }
  end

  defp exact_profiles do
    ProfileRegistry.exact_profiles(builtin_profiles(), @registry_key)
  end

  defp normalize_general_purpose(nil), do: %GeneralPurposeSubagentProfile{}
  defp normalize_general_purpose(%GeneralPurposeSubagentProfile{} = profile), do: profile

  defp normalize_general_purpose(profile) when is_map(profile) or is_list(profile),
    do: GeneralPurposeSubagentProfile.new(profile)

  defp maybe_put_default_subagent(opts, %GeneralPurposeSubagentProfile{enabled: false}),
    do: Map.put(opts, :default_subagent?, false)

  defp maybe_put_default_subagent(opts, %GeneralPurposeSubagentProfile{enabled: true}),
    do: Map.put(opts, :default_subagent?, true)

  defp maybe_put_default_subagent(opts, _gp),
    do: Map.put_new(opts, :default_subagent?, Map.get(opts, :default_subagent?, true))

  defp maybe_put_gp(map, %GeneralPurposeSubagentProfile{} = gp) do
    case GeneralPurposeSubagentProfile.to_map(gp) do
      empty when map_size(empty) == 0 -> map
      gp_map -> Map.put(map, :general_purpose_subagent, gp_map)
    end
  end

  defp merge_general_purpose(
         %GeneralPurposeSubagentProfile{} = base,
         %GeneralPurposeSubagentProfile{} = override
       ) do
    GeneralPurposeSubagentProfile.new(
      enabled: if(is_nil(override.enabled), do: base.enabled, else: override.enabled),
      description: override.description || base.description,
      system_prompt: override.system_prompt || base.system_prompt
    )
  end

  defp merge_general_purpose(nil, override), do: override
  defp merge_general_purpose(base, nil), do: base

  defp merged_default_subagent?(_base, _override, %GeneralPurposeSubagentProfile{enabled: false}),
    do: false

  defp merged_default_subagent?(_base, _override, %GeneralPurposeSubagentProfile{enabled: true}),
    do: true

  defp merged_default_subagent?(base, override, _gp),
    do: base.default_subagent? and override.default_subagent?

  defp merge_middleware(base, override) do
    base = resolve_middleware(base)
    override = resolve_middleware(override)

    override_by_type =
      Map.new(override, fn middleware -> {middleware_key(middleware), middleware} end)

    {merged, replaced} =
      Enum.reduce(base, {[], MapSet.new()}, fn middleware, {acc, replaced} ->
        key = middleware_key(middleware)

        cond do
          Map.has_key?(override_by_type, key) and not MapSet.member?(replaced, key) ->
            {[Map.fetch!(override_by_type, key) | acc], MapSet.put(replaced, key)}

          Map.has_key?(override_by_type, key) ->
            {acc, replaced}

          true ->
            {[middleware | acc], replaced}
        end
      end)

    novel = Enum.reject(override, &MapSet.member?(replaced, middleware_key(&1)))
    Enum.reverse(merged) ++ novel
  end

  defp resolve_middleware(middleware) when is_function(middleware, 0),
    do: middleware.() |> List.wrap()

  defp resolve_middleware(middleware), do: List.wrap(middleware)

  defp middleware_key(%module{}), do: module
  defp middleware_key(%{__struct__: module}), do: module
  defp middleware_key(other), do: other

  defp union_terms(left, right) do
    (List.wrap(left) ++ List.wrap(right))
    |> Enum.uniq()
    |> Enum.sort_by(&inspect/1)
  end
end
