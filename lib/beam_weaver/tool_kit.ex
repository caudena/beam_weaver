defmodule BeamWeaver.ToolKit do
  @moduledoc """
  Behaviour for modules that expose a collection of tools.
  """

  alias BeamWeaver.Core.Error

  @callback tools(keyword()) :: [term()] | {:ok, [term()]} | {:error, Error.t()}

  @doc """
  Loads tools from a toolkit module or struct.
  """
  @spec tools(module() | struct(), keyword()) :: {:ok, [term()]} | {:error, Error.t()}
  def tools(toolkit, opts \\ [])

  def tools(module, opts) when is_atom(module) do
    normalize_result(module.tools(opts))
  end

  def tools(%module{} = toolkit, opts) do
    normalize_result(module.tools(toolkit, opts))
  end

  defp normalize_result({:ok, tools}) when is_list(tools), do: {:ok, tools}
  defp normalize_result({:error, %Error{}} = error), do: error
  defp normalize_result(tools) when is_list(tools), do: {:ok, tools}
end
