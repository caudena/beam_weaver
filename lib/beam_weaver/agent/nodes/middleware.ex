defmodule BeamWeaver.Agent.Nodes.Middleware do
  @moduledoc false

  alias BeamWeaver.Agent.Decision
  alias BeamWeaver.Agent.Middleware
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Graph.Command

  defstruct [:middleware, :hook]

  def new(middleware, hook), do: %__MODULE__{middleware: middleware, hook: hook}

  def invoke(%__MODULE__{middleware: middleware, hook: hook}, state, runtime) do
    result = Middleware.call_hook(middleware, hook, state, runtime)

    normalize_result(result, state)
  rescue
    exception ->
      {:error,
       Error.new(:agent_middleware_error, Exception.message(exception), %{
         middleware: Middleware.name(middleware),
         hook: hook
       })}
  end

  defp normalize_result(nil, _state), do: %{}
  defp normalize_result(%Command{} = command, _state), do: command

  defp normalize_result(other, state) do
    case Decision.normalize(other) do
      {:ok, decision} -> decision |> Decision.to_update() |> state_delta(state)
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp state_delta(update, state) when is_map(update) and is_map(state) do
    Map.reject(update, fn {key, value} ->
      state_value(state, key) == {:ok, value}
    end)
  end

  defp state_delta(update, _state), do: update

  defp state_value(state, key) when is_atom(key) do
    cond do
      Map.has_key?(state, key) -> {:ok, Map.fetch!(state, key)}
      Map.has_key?(state, Atom.to_string(key)) -> {:ok, Map.fetch!(state, Atom.to_string(key))}
      true -> :error
    end
  end

  defp state_value(state, key) when is_binary(key) do
    if Map.has_key?(state, key) do
      {:ok, Map.fetch!(state, key)}
    else
      atom = String.to_existing_atom(key)

      if Map.has_key?(state, atom), do: {:ok, Map.fetch!(state, atom)}, else: :error
    end
  rescue
    ArgumentError -> :error
  end
end
