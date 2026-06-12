defmodule BeamWeaver.Agent.Middleware.Capabilities do
  @moduledoc false

  @type middleware :: module() | struct()

  @spec name(middleware()) :: String.t()
  def name(middleware) do
    module = middleware_module(middleware)

    cond do
      function_exported?(module, :name, 1) ->
        middleware |> module.name() |> to_string()

      is_atom(middleware) ->
        inspect(middleware)

      true ->
        module |> Module.split() |> List.last()
    end
  end

  @spec state_schema(middleware()) :: map() | nil
  def state_schema(middleware), do: optional(middleware, :state_schema, [])

  @spec context_schema(middleware()) :: map() | nil
  def context_schema(middleware), do: optional(middleware, :context_schema, [])

  @spec tools(middleware()) :: [term()]
  def tools(middleware), do: optional(middleware, :tools, []) || []

  @spec tool_node_required?(middleware()) :: boolean()
  def tool_node_required?(middleware),
    do: optional(middleware, :tool_node_required?, []) == true

  @spec can_jump_to(middleware(), atom()) :: [:model | :tools | :end]
  def can_jump_to(middleware, hook), do: optional(middleware, :can_jump_to, [hook]) || []

  @spec requires_checkpointer?(middleware()) :: boolean()
  def requires_checkpointer?(middleware),
    do: optional(middleware, :requires_checkpointer?, []) == true

  defp optional(middleware, function, extra_args) do
    module = middleware_module(middleware)
    Code.ensure_loaded?(module)

    if function_exported?(module, function, length(extra_args) + 1) do
      apply(module, function, [middleware | extra_args])
    end
  end

  defp middleware_module(module) when is_atom(module), do: module
  defp middleware_module(%{__struct__: module}), do: module
end
