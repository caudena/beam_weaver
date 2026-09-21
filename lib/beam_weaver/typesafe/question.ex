defmodule BeamWeaver.TypeSafe.Question do
  @moduledoc """
  Typed questions for Jev. Instructions and criteria can contain structured JSON.

  Choice criteria map option names to descriptions. Score criteria contain
  2–10 ordered levels. Noul criteria optionally describe `true` and `false`.
  Question IDs are correlation keys; put the complete question in instructions.
  Constructors produce data; invocation validates it before sending a request.
  """

  defstruct [:type, :instructions, :criteria]
  @type t :: %__MODULE__{type: :choice | :score | :noul, instructions: term(), criteria: term()}

  def choice(opts), do: new(:choice, opts)
  def score(opts), do: new(:score, opts)
  def noul(opts), do: new(:noul, opts)

  defp new(type, opts), do: struct!(__MODULE__, Keyword.put(Map.to_list(Map.new(opts)), :type, type))
end
