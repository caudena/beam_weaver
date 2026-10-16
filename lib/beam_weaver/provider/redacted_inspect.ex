defmodule BeamWeaver.Provider.RedactedInspect do
  @moduledoc false

  # `use BeamWeaver.Provider.RedactedInspect` in a struct module inspects it
  # through `Transport.Redactor`, so credentials and auth headers never reach
  # logs or IEx output.
  defmacro __using__(_opts) do
    quote do
      defimpl Inspect do
        def inspect(struct, opts), do: BeamWeaver.Provider.RedactedInspect.redacted_struct(struct, opts)
      end
    end
  end

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
