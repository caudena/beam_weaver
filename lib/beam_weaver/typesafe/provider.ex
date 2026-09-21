defmodule BeamWeaver.TypeSafe.Provider do
  @moduledoc false
  @behaviour BeamWeaver.Provider.Adapter
  alias BeamWeaver.Core.Error

  def provider, do: :typesafe
  def profiles, do: BeamWeaver.Models.ProfileRegistry.profiles(:typesafe)
  def profile(model), do: BeamWeaver.Models.ProfileRegistry.fetch(:typesafe, model)
  def decision_model(_opts), do: {:ok, BeamWeaver.TypeSafe.DecisionModel}
  def chat_model(_opts), do: unsupported()
  def embedding_model(_opts), do: unsupported()
  def default_model(:decision), do: "jev-latest"
  def default_model(_), do: nil
  def infer_provider?(_, _), do: false
  def capabilities, do: %{api_families: [:system_one], model_kinds: [:decision], primitives: [:choice, :score, :noul]}

  defp unsupported,
    do: {:error, Error.new(:unsupported_feature, "Jev is a decision model; use Models.init_decision_model/2")}
end
