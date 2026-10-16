defmodule BeamWeaver.Agent.Nodes.Middleware do
  @moduledoc false

  alias BeamWeaver.Agent.Decision
  alias BeamWeaver.Agent.Middleware
  alias BeamWeaver.Core.Error
  alias BeamWeaver.Graph.Command

  defstruct [:middleware, :hook]

  def new(middleware, hook), do: %__MODULE__{middleware: middleware, hook: hook}

  # The hook's update is written as it is, like a node's: a key with a
  # reducer, such as an append, gets the value even when it equals the
  # current one.
  def invoke(%__MODULE__{middleware: middleware, hook: hook}, state, runtime) do
    middleware
    |> Middleware.call_hook(hook, state, runtime)
    |> normalize_result()
  rescue
    exception ->
      {:error,
       Error.new(:agent_middleware_error, Exception.message(exception), %{
         middleware: Middleware.name(middleware),
         hook: hook
       })}
  end

  defp normalize_result(nil), do: %{}
  defp normalize_result(%Command{} = command), do: command

  defp normalize_result(other) do
    case Decision.normalize(other) do
      {:ok, decision} -> Decision.to_update(decision)
      {:error, %Error{} = error} -> {:error, error}
    end
  end
end
