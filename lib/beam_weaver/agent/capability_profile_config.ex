defmodule BeamWeaver.Agent.CapabilityProfileConfig do
  @moduledoc "Serializable configuration form for `CapabilityProfile`."

  alias BeamWeaver.Agent.CapabilityProfile
  alias BeamWeaver.Agent.GeneralPurposeSubagentProfile
  alias BeamWeaver.Agent.ProfileRegistry

  @type t :: %__MODULE__{}

  defstruct base_system_prompt: nil,
            system_prompt_suffix: nil,
            tool_description_overrides: %{},
            excluded_tools: [],
            excluded_middleware: [],
            general_purpose_subagent: nil

  def new(opts \\ []) when is_list(opts) or is_map(opts) do
    opts = if is_map(opts), do: opts, else: Map.new(opts)
    struct(__MODULE__, normalize_keys(opts))
  end

  def from_map(map) when is_map(map), do: new(map)

  def from_capability_profile(%CapabilityProfile{} = profile),
    do: new(CapabilityProfile.to_map(profile))

  def to_capability_profile(%__MODULE__{} = config) do
    CapabilityProfile.new(
      base_system_prompt: config.base_system_prompt,
      system_prompt_suffix: config.system_prompt_suffix,
      tool_description_overrides: config.tool_description_overrides,
      excluded_tools: config.excluded_tools,
      excluded_middleware: config.excluded_middleware,
      general_purpose_subagent: config.general_purpose_subagent
    )
  end

  def to_map(%__MODULE__{} = config) do
    %{}
    |> ProfileRegistry.maybe_put(:base_system_prompt, config.base_system_prompt)
    |> ProfileRegistry.maybe_put(:system_prompt_suffix, config.system_prompt_suffix)
    |> ProfileRegistry.maybe_put_map(
      :tool_description_overrides,
      config.tool_description_overrides
    )
    |> ProfileRegistry.maybe_put_list(:excluded_tools, config.excluded_tools)
    |> ProfileRegistry.maybe_put_list(:excluded_middleware, config.excluded_middleware)
    |> maybe_put_gp(config.general_purpose_subagent)
  end

  defp normalize_keys(opts) do
    Map.new(opts, fn
      {"base_system_prompt", value} ->
        {:base_system_prompt, value}

      {"system_prompt_suffix", value} ->
        {:system_prompt_suffix, value}

      {"tool_description_overrides", value} ->
        {:tool_description_overrides, value}

      {"excluded_tools", value} ->
        {:excluded_tools, List.wrap(value)}

      {"excluded_middleware", value} ->
        {:excluded_middleware, List.wrap(value)}

      {"general_purpose_subagent", value} ->
        {:general_purpose_subagent, GeneralPurposeSubagentProfile.new(value)}

      {:general_purpose_subagent, value} when not is_nil(value) ->
        {:general_purpose_subagent, GeneralPurposeSubagentProfile.new(value)}

      pair ->
        pair
    end)
  end

  defp maybe_put_gp(map, nil), do: map

  defp maybe_put_gp(map, %GeneralPurposeSubagentProfile{} = gp) do
    case GeneralPurposeSubagentProfile.to_map(gp) do
      empty when map_size(empty) == 0 -> Map.put(map, :general_purpose_subagent, %{})
      gp_map -> Map.put(map, :general_purpose_subagent, gp_map)
    end
  end
end
