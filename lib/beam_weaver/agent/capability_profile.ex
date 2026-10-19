defmodule BeamWeaver.Agent.CapabilityProfile do
  @moduledoc """
  Per-model tuning for a deep agent: system prompt text, hidden tools, tool
  descriptions, extra middleware and general-purpose subagent settings.

  An agent applies a profile with the `capability_profile` declaration:
  `capability_profile :auto` uses `for_model/2` for the agent's model, and
  `capability_profile profile` uses the one you give. See
  [Capability Profiles](profiles.md).
  """

  alias BeamWeaver.Agent.CapabilityProfileConfig
  alias BeamWeaver.Agent.GeneralPurposeSubagentProfile
  alias BeamWeaver.Agent.ProfileRegistry
  alias BeamWeaver.MapShape

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

  def builtin(name) when name in [nil, :default], do: new(name: :default)

  def builtin(:anthropic) do
    new(
      name: :anthropic,
      prompt_suffix: "Use tools carefully and keep intermediate artifacts in the filesystem."
    )
  end

  def builtin(:anthropic_haiku_4_5), do: builtin("anthropic:claude-haiku-4-5")
  def builtin(:anthropic_sonnet_4_6), do: builtin("anthropic:claude-sonnet-4-6")
  def builtin(:anthropic_fable_5_1), do: builtin("anthropic:claude-fable-5-1")
  def builtin(:anthropic_mythos_5_1), do: builtin("anthropic:claude-mythos-5-1")
  def builtin(:anthropic_fable_5), do: builtin("anthropic:claude-fable-5")
  def builtin(:anthropic_mythos_5), do: builtin("anthropic:claude-mythos-5")
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

  @doc "Returns built-in capability profile keys."
  @spec builtin_keys() :: [String.t()]
  def builtin_keys, do: Map.keys(builtin_profiles()) |> Enum.sort()

  @doc "Registers or merges a capability profile under a provider or provider:model key."
  @spec register_capability_profile(String.t() | atom(), __MODULE__.t() | term()) :: :ok
  def register_capability_profile(key, profile) do
    ProfileRegistry.register(@registry_key, builtin_profiles(), key, builtin(profile), &merge/2)
  end

  @doc """
  Looks up a capability profile for a provider or provider:model spec.

  Exact model profiles are layered on top of provider-level profiles.
  Malformed specs return `nil` instead of falling back to the provider half.
  """
  @spec get_capability_profile(String.t() | atom() | nil) :: __MODULE__.t() | nil
  def get_capability_profile(nil), do: nil

  def get_capability_profile(spec) when is_atom(spec) or is_binary(spec) do
    ProfileRegistry.lookup(@registry_key, builtin_profiles(), spec, &merge/2)
  end

  @doc "Returns the capability profile that best matches a raw or resolved model."
  @spec for_model(term(), String.t() | nil) :: __MODULE__.t()
  def for_model(model, spec \\ nil),
    do: ProfileRegistry.for_model(model, spec, &get_capability_profile/1) || new(name: :default)

  @doc "Materializes the profile middleware list, invoking a zero-arity factory if present."
  @spec materialize_extra_middleware(__MODULE__.t()) :: [term()]
  def materialize_extra_middleware(%__MODULE__{middleware: middleware}), do: resolve_middleware(middleware)

  @doc """
  Merges `override` into `base`.

  Prompt texts set in `override` win, tool descriptions and middleware merge by
  tool name and middleware module (`override` wins), and excluded tools and
  middleware are combined.
  """
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
    |> MapShape.put_present(:base_system_prompt, profile.base_system_prompt)
    |> MapShape.put_present(:system_prompt_suffix, profile.prompt_suffix)
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

    named = [
      {anthropic_universal, ~w(anthropic:claude-haiku-4-5 anthropic:claude-sonnet-4-6)},
      {anthropic_opus, ~w(anthropic:claude-fable-5-1 anthropic:claude-mythos-5-1 anthropic:claude-fable-5)},
      {anthropic_opus, ~w(anthropic:claude-mythos-5 anthropic:claude-opus-4-8 anthropic:claude-opus-4-7)},
      {codex, ~w(openai:gpt-5.5 openai:gpt-5.4 openai:gpt-5.4-mini)}
    ]

    for {profile, keys} <- named,
        key <- keys,
        into: %{"anthropic" => anthropic_universal},
        do: {key, %{profile | name: key}}
  end

  defp normalize_general_purpose(nil), do: %GeneralPurposeSubagentProfile{}
  defp normalize_general_purpose(%GeneralPurposeSubagentProfile{} = profile), do: profile

  defp normalize_general_purpose(profile) when is_map(profile) or is_list(profile),
    do: GeneralPurposeSubagentProfile.new(profile)

  defp maybe_put_default_subagent(opts, %GeneralPurposeSubagentProfile{enabled: enabled}) when is_boolean(enabled),
    do: Map.put(opts, :default_subagent?, enabled)

  defp maybe_put_default_subagent(opts, _gp), do: opts

  defp maybe_put_gp(map, %GeneralPurposeSubagentProfile{} = gp) do
    case GeneralPurposeSubagentProfile.to_map(gp) do
      empty when map_size(empty) == 0 -> map
      gp_map -> Map.put(map, :general_purpose_subagent, gp_map)
    end
  end

  defp merge_general_purpose(nil, override), do: override
  defp merge_general_purpose(base, nil), do: base
  defp merge_general_purpose(base, override), do: GeneralPurposeSubagentProfile.merge(base, override)

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
  defp middleware_key(other), do: other

  defp union_terms(left, right) do
    (List.wrap(left) ++ List.wrap(right))
    |> Enum.uniq()
    |> Enum.sort_by(&inspect/1)
  end
end
