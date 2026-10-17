defmodule BeamWeaver.Prompt.Partials do
  @moduledoc false

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Prompt.StringTemplate
  alias BeamWeaver.Prompt.Variables
  alias BeamWeaver.Result

  def merge_vars(partials, input) do
    vars = if is_map(input), do: input, else: %{input: input}

    with {:ok, partials} <-
           partials |> Map.new() |> drop_overridden(vars) |> Result.traverse(&resolve_partial(&1, input)) do
      {:ok, partials |> Map.new() |> Map.merge(vars)}
    end
  end

  # A variable overrides the partial of the same name whether either uses an
  # atom or a string key.
  def merge(partials, vars), do: partials |> drop_overridden(vars) |> Map.merge(vars)

  defp drop_overridden(partials, vars) do
    names = MapSet.new(Map.keys(vars), &Kernel.to_string/1)
    Map.reject(partials, fn {key, _value} -> MapSet.member?(names, Kernel.to_string(key)) end)
  end

  def validate_input(%StringTemplate{validate?: true} = prompt, vars) do
    expected = MapSet.new(Variables.variables(prompt))
    partial_keys = MapSet.new(Map.keys(prompt.partials || %{}), &Kernel.to_string/1)

    actual =
      vars
      |> Map.keys()
      |> Enum.map(&Kernel.to_string/1)
      |> MapSet.new()
      |> MapSet.difference(partial_keys)

    extra = MapSet.difference(actual, expected) |> MapSet.to_list()

    if extra == [] do
      :ok
    else
      {:error, Error.new(:prompt_extra_variable, "prompt received extra variables", %{extra: extra})}
    end
  end

  def validate_input(_prompt, _vars), do: :ok

  def fetch_var(vars, key) do
    key = Kernel.to_string(key)

    Enum.find_value(vars, :error, fn {candidate, value} ->
      if Kernel.to_string(candidate) == key, do: {:ok, value}, else: nil
    end)
  end

  defp resolve_partial({key, fun}, _input) when is_function(fun, 0), do: call_partial(key, fun, %{})
  defp resolve_partial({key, fun}, input) when is_function(fun, 1), do: call_partial(key, fn -> fun.(input) end, %{})

  defp resolve_partial({key, {module, function, args} = callback}, input)
       when is_atom(module) and is_atom(function) and is_list(args),
       do: call_partial(key, fn -> apply(module, function, [input | args]) end, %{callback: inspect(callback)})

  defp resolve_partial(partial, _input), do: {:ok, partial}

  defp call_partial(key, fun, details) do
    {:ok, {key, fun.()}}
  rescue
    exception ->
      {:error,
       Error.new(
         :prompt_partial_error,
         "prompt partial callback failed",
         Map.put(details, :reason, Exception.message(exception))
       )}
  end
end
