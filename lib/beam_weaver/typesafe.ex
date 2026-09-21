defmodule BeamWeaver.TypeSafe do
  @moduledoc "Native TypeSafe System One integration for Jev typed decisions."
  defdelegate client(opts \\ []), to: BeamWeaver.TypeSafe.Client, as: :new
  defdelegate decision_model(opts \\ []), to: BeamWeaver.TypeSafe.DecisionModel, as: :new
end
