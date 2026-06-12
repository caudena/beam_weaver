defmodule BeamWeaver.Agent.GeneralPurposeSubagentProfile do
  @moduledoc "Configuration for the auto-added general-purpose subagent."

  @type t :: %__MODULE__{}

  defstruct enabled: nil, description: nil, system_prompt: nil

  def new(opts \\ []) when is_list(opts) or is_map(opts) do
    opts = if is_map(opts), do: opts, else: Map.new(opts)
    struct(__MODULE__, normalize_keys(opts))
  end

  def to_map(%__MODULE__{} = profile) do
    %{}
    |> maybe_put(:enabled, profile.enabled)
    |> maybe_put(:description, profile.description)
    |> maybe_put(:system_prompt, profile.system_prompt)
  end

  def from_map(map) when is_map(map) do
    unknown =
      Map.keys(map) --
        [:enabled, :description, :system_prompt, "enabled", "description", "system_prompt"]

    if unknown != [] do
      raise ArgumentError, "unknown general-purpose subagent profile keys: #{inspect(unknown)}"
    end

    new(map)
  end

  defp normalize_keys(opts) do
    Map.new(opts, fn
      {"enabled", value} -> {:enabled, value}
      {"description", value} -> {:description, value}
      {"system_prompt", value} -> {:system_prompt, value}
      pair -> pair
    end)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
