defmodule BeamWeaver.Agent.Middleware.Hooks do
  @moduledoc false

  @type middleware :: module() | struct()
  @type hook_result ::
          nil
          | map()
          | {:ok, map()}
          | {:error, term()}
          | {:jump, :model | :tools | :end, map()}
          | BeamWeaver.Graph.Command.t()

  @hooks [
    :before_agent,
    :before_model,
    :after_model,
    :after_agent,
    :wrap_model_call,
    :wrap_tool_call
  ]

  @spec hook?(middleware(), atom()) :: boolean()
  def hook?(middleware, hook) when hook in @hooks do
    module = middleware_module(middleware)
    function_exported?(module, hook, 2) or function_exported?(module, hook, 3)
  end

  def hook?(_middleware, _hook), do: false

  @spec call_hook(middleware(), atom(), map(), BeamWeaver.Graph.Runtime.t()) :: hook_result()
  def call_hook(middleware, hook, state, runtime)
      when hook in [:before_agent, :before_model, :after_model, :after_agent] do
    module = middleware_module(middleware)

    cond do
      function_exported?(module, hook, 3) -> apply(module, hook, [middleware, state, runtime])
      function_exported?(module, hook, 2) -> apply(module, hook, [state, runtime])
    end
  end

  @spec call_wrapper(middleware(), :wrap_model_call | :wrap_tool_call, term(), function()) ::
          term()
  def call_wrapper(middleware, hook, request, handler)
      when hook in [:wrap_model_call, :wrap_tool_call] do
    module = middleware_module(middleware)

    cond do
      function_exported?(module, hook, 3) -> apply(module, hook, [middleware, request, handler])
      function_exported?(module, hook, 2) -> apply(module, hook, [request, handler])
    end
  end

  defp middleware_module(module) when is_atom(module), do: module
  defp middleware_module(%{__struct__: module}), do: module
end
