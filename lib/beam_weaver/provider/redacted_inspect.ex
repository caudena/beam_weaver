defmodule BeamWeaver.Provider.RedactedInspect do
  @moduledoc false

  import Inspect.Algebra

  alias BeamWeaver.Transport.Redactor

  @spec redacted_struct(struct(), Inspect.Opts.t()) :: Inspect.Algebra.t()
  def redacted_struct(%module{} = struct, opts) do
    fields =
      struct
      |> Map.from_struct()
      |> Redactor.redact()

    concat(["#", module_name(module), "<", to_doc(fields, opts), ">"])
  end

  defp module_name(module) do
    module
    |> Atom.to_string()
    |> String.trim_leading("Elixir.")
  end
end
