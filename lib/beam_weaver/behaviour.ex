defmodule BeamWeaver.Behaviour do
  @moduledoc false

  @doc "Whether `module` declares `behaviour`, directly or through a `use` macro."
  @spec implemented_by?(module(), module()) :: boolean()
  def implemented_by?(module, behaviour) when is_atom(module) do
    Code.ensure_loaded?(module) and
      behaviour in (module.module_info(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten())
  end

  @doc """
  Whether `module` exports `fun/arity`, loading the module first.

  Plain `function_exported?/3` is false for a module that is not loaded yet,
  which is common in interactive mode: building a struct literal does not load
  its module.
  """
  @spec exported?(module(), atom(), arity()) :: boolean()
  def exported?(module, fun, arity) when is_atom(module),
    do: Code.ensure_loaded?(module) and function_exported?(module, fun, arity)
end
