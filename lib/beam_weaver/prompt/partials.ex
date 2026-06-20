defmodule BeamWeaver.Prompt.Partials do
  @moduledoc false

  alias BeamWeaver.Core.Error
  alias BeamWeaver.Prompt.StringTemplate
  alias BeamWeaver.Prompt.Variables

  def merge_vars(partials, input) do
    base =
      partials
      |> Map.new()
      |> resolve_partials(input)

    input =
      if is_map(input),
        do: input,
        else: %{input: input}

    case base do
      {:ok, partials} -> {:ok, Map.merge(partials, input)}
      {:error, %Error{} = error} -> {:error, error}
    end
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

  defp resolve_partials(partials, input) do
    Enum.reduce_while(partials, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case resolve_partial(value, input) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, key, value)}}
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp resolve_partial(fun, _input) when is_function(fun, 0) do
    {:ok, fun.()}
  rescue
    exception ->
      {:error,
       Error.new(:prompt_partial_error, "prompt partial callback failed", %{
         reason: Exception.message(exception)
       })}
  end

  defp resolve_partial(fun, input) when is_function(fun, 1) do
    {:ok, fun.(input)}
  rescue
    exception ->
      {:error,
       Error.new(:prompt_partial_error, "prompt partial callback failed", %{
         reason: Exception.message(exception)
       })}
  end

  defp resolve_partial({module, function, args}, input)
       when is_atom(module) and is_atom(function) and is_list(args) do
    {:ok, apply(module, function, [input | args])}
  rescue
    exception ->
      {:error,
       Error.new(:prompt_partial_error, "prompt partial callback failed", %{
         reason: Exception.message(exception),
         callback: inspect({module, function, args})
       })}
  end

  defp resolve_partial(value, _input), do: {:ok, value}
end
