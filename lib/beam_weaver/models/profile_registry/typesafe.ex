defmodule BeamWeaver.Models.ProfileRegistry.TypeSafe do
  @moduledoc false
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Models.Profile

  # Source: https://docs.typesafe.ai/models, verified 2026-09-21.
  @known ["jev-1.13.0", "jev-latest", "jev-preview"]
  def profiles, do: Enum.map(@known, &profile/1)

  def resolve("jev-" <> suffix = id) when suffix != "", do: {:ok, profile(id)}
  def resolve(id), do: {:error, Error.new(:invalid_model, "unsupported TypeSafe model identifier", %{model: id})}

  defp profile(id) do
    known? = id in @known

    extra = %{
      model_kind: :decision,
      primitives: [:choice, :score, :noul],
      source: "https://docs.typesafe.ai/models",
      verified_at: "2026-09-21"
    }

    extra =
      if known?,
        do:
          Map.merge(extra, %{
            state_plus_longest_question_tokens: 32_000,
            input_price_per_mtok: 0.042,
            output_price_per_mtok: 0.0
          }),
        else: Map.put(extra, :unknown, true)

    extra = if id in ["jev-latest", "jev-preview"], do: Map.put(extra, :alias_of, "jev-1.13.0"), else: extra

    Profile.new(
      provider: :typesafe,
      id: id,
      name: id,
      last_updated: "2026-09-21",
      text_outputs: false,
      decision_outputs: true,
      temperature: false,
      usage_metadata: true,
      max_input_tokens: if(known?, do: 64_000),
      supported_params: [:model, :state, :questions],
      supported_params_by_api: %{system_one: [:model, :state, :questions]},
      extra: extra
    )
  end
end
