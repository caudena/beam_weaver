defmodule BeamWeaver.Google.Error do
  @moduledoc """
  Recoverable errors returned by the Google Gemini provider.
  """

  defexception [:type, :message, details: %{}]

  @type t :: %__MODULE__{type: atom(), message: String.t(), details: map()}

  def new(type, message, details \\ %{}) do
    %__MODULE__{type: type, message: message, details: details}
  end
end
