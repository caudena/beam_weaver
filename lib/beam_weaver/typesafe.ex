defmodule BeamWeaver.TypeSafe do
  @moduledoc ~S"""
  Construct Jev typed-decision models and an account model-list client.

  Configure credentials in the application's :typesafe group or pass explicit
  connection options. Jev answers named choice, score and yes/no probability
  questions through BeamWeaver.Core.DecisionModel; it does not provide chat,
  function tools or token streaming. Construction performs no inference.
  See [TypeSafe](providers/typesafe.md) for live decisions and model routing.
  """
  defdelegate client(opts \\ []), to: BeamWeaver.TypeSafe.Client, as: :new
  defdelegate decision_model(opts \\ []), to: BeamWeaver.TypeSafe.DecisionModel, as: :new
end
