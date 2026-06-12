defmodule BeamWeaver.Tools.Shell.Executor do
  @moduledoc """
  Behaviour for shell execution backends.
  """

  alias BeamWeaver.Core.Error
  alias BeamWeaver.ShellPolicy

  @callback run(String.t(), ShellPolicy.t(), keyword()) ::
              {:ok, map()} | {:error, Error.t()}
end
