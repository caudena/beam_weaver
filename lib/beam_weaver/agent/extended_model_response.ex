defmodule BeamWeaver.Agent.ExtendedModelResponse do
  @moduledoc """
  Model response plus an optional state command returned by wrap-model middleware.
  """

  defstruct [:model_response, :command]

  @type t :: %__MODULE__{
          model_response: BeamWeaver.Agent.ModelResponse.t(),
          command: BeamWeaver.Graph.Command.t() | nil
        }
end
