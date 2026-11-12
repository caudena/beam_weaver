defmodule BeamWeaver.Google.Decisions.Question do
  @moduledoc """
  Questions for Gemini Decision 1.

  Each question takes text instructions. A choice uses a map from option names
  to descriptions. A score uses a list of descriptions ordered from lowest to
  highest. A noul question optionally takes `true_description` and
  `false_description` in its criteria map.
  """

  defstruct [:type, :instructions, :criteria]

  def noul(opts), do: new(:noul, opts)
  def choice(opts), do: new(:choice, opts)
  def score(opts), do: new(:score, opts)

  defp new(type, opts), do: struct!(__MODULE__, Map.put(Map.new(opts), :type, type))
end
