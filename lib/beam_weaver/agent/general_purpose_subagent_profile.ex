defmodule BeamWeaver.Agent.GeneralPurposeSubagentProfile do
  @moduledoc """
  Settings for the built-in `general-purpose` subagent.

  List one with an agent's subagents to apply it: `description` and
  `system_prompt` replace the subagent's texts, and `enabled: false` leaves
  it out.

      subagents do
        subagent MyApp.PolicyExpert
        include [BeamWeaver.Agent.GeneralPurposeSubagentProfile.new(enabled: false)]
      end

  A `BeamWeaver.Agent.CapabilityProfile` holds one in its
  `general_purpose_subagent` field. See [Subagents](subagents.md).
  """

  import BeamWeaver.MapShape, only: [put_present: 3]

  @type t :: %__MODULE__{}

  defstruct enabled: nil, description: nil, system_prompt: nil

  def new(opts \\ []) when is_list(opts) or is_map(opts) do
    opts = if is_map(opts), do: opts, else: Map.new(opts)
    struct(__MODULE__, normalize_keys(opts))
  end

  def to_map(%__MODULE__{} = profile) do
    %{}
    |> put_present(:enabled, profile.enabled)
    |> put_present(:description, profile.description)
    |> put_present(:system_prompt, profile.system_prompt)
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
end
