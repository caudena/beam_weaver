defmodule BeamWeaver.Agent.GeneralPurposeSubagentProfile do
  @moduledoc """
  Settings for the built-in `general-purpose` subagent.

  List one with an agent's subagents to apply it: `description` and
  `system_prompt` replace the subagent's texts, and `enabled: false` leaves
  it out.

  ```elixir
  profile = BeamWeaver.Agent.GeneralPurposeSubagentProfile.new(enabled: false)
  BeamWeaver.Agent.GeneralPurposeSubagentProfile.to_map(profile)
  #=> %{enabled: false}
  ```

  Put this profile in a `subagents` block with `include [profile]`, alongside
  explicitly declared specialists. [Subagents](subagents.md#the-general-purpose-subagent)
  contains complete parent and specialist modules.

  A `BeamWeaver.Agent.CapabilityProfile` holds one in its
  `general_purpose_subagent` field. See [Subagents](subagents.md).
  """

  import BeamWeaver.MapShape, only: [put_present: 3]

  @type t :: %__MODULE__{}

  defstruct enabled: nil, description: nil, system_prompt: nil

  def new(opts \\ []) when is_list(opts) or is_map(opts), do: struct(__MODULE__, normalize_keys(opts))

  def to_map(%__MODULE__{} = profile) do
    %{}
    |> put_present(:enabled, profile.enabled)
    |> put_present(:description, profile.description)
    |> put_present(:system_prompt, profile.system_prompt)
  end

  @doc false
  # `override`'s settings, and `base`'s where `override` has none.
  def merge(%__MODULE__{} = base, %__MODULE__{} = override) do
    %__MODULE__{
      enabled: if(is_nil(override.enabled), do: base.enabled, else: override.enabled),
      description: override.description || base.description,
      system_prompt: override.system_prompt || base.system_prompt
    }
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
