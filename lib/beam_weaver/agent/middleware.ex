defmodule BeamWeaver.Agent.Middleware do
  @moduledoc """
  Behaviour and helpers for agent middleware modules.

  Middleware is ordinary Elixir data. A middleware entry can be a module, a
  struct, or `{module, opts}`. Hook callbacks are optional and are discovered at
  graph compilation time.
  """

  alias BeamWeaver.Agent.Middleware.Capabilities
  alias BeamWeaver.Agent.Middleware.Hooks
  alias BeamWeaver.Agent.Middleware.Normalize
  alias BeamWeaver.Core.Error

  @type t :: module() | struct()

  @callback name(term()) :: atom() | String.t()
  @callback state_schema(term()) :: map() | nil
  @callback context_schema(term()) :: map() | nil
  @callback tools(term()) :: [term()]
  @callback tool_node_required?(term()) :: boolean()
  @callback can_jump_to(term(), atom()) :: [:model | :tools | :end]
  @callback requires_checkpointer?(term()) :: boolean()
  @callback before_agent(map(), BeamWeaver.Graph.Runtime.t()) :: hook_result()
  @callback before_model(map(), BeamWeaver.Graph.Runtime.t()) :: hook_result()
  @callback after_model(map(), BeamWeaver.Graph.Runtime.t()) :: hook_result()
  @callback after_agent(map(), BeamWeaver.Graph.Runtime.t()) :: hook_result()
  @callback wrap_model_call(BeamWeaver.Agent.ModelRequest.t(), function()) :: term()
  @callback wrap_tool_call(BeamWeaver.Agent.ToolCallRequest.t(), function()) :: term()

  @optional_callbacks name: 1,
                      state_schema: 1,
                      context_schema: 1,
                      tools: 1,
                      tool_node_required?: 1,
                      can_jump_to: 2,
                      requires_checkpointer?: 1,
                      before_agent: 2,
                      before_model: 2,
                      after_model: 2,
                      after_agent: 2,
                      wrap_model_call: 2,
                      wrap_tool_call: 2

  @type hook_result ::
          nil
          | map()
          | {:ok, map()}
          | {:error, term()}
          | {:jump, :model | :tools | :end, map()}
          | BeamWeaver.Graph.Command.t()

  @doc "Normalizes a middleware entry into a module or struct."
  @spec normalize(term()) :: {:ok, t()} | {:error, Error.t()}
  defdelegate normalize(entry), to: Normalize

  @doc "Normalizes a list of middleware entries."
  @spec normalize_all([term()]) :: {:ok, [t()]} | {:error, Error.t()}
  defdelegate normalize_all(entries), to: Normalize

  @doc "Returns the stable middleware name."
  @spec name(t()) :: String.t()
  defdelegate name(middleware), to: Capabilities

  @doc false
  @spec hook?(t(), atom()) :: boolean()
  defdelegate hook?(middleware, hook), to: Hooks

  @doc false
  @spec call_hook(t(), atom(), map(), BeamWeaver.Graph.Runtime.t()) :: hook_result()
  defdelegate call_hook(middleware, hook, state, runtime), to: Hooks

  @doc false
  @spec call_wrapper(t(), :wrap_model_call | :wrap_tool_call, term(), function()) :: term()
  defdelegate call_wrapper(middleware, hook, request, handler), to: Hooks

  @doc "Returns middleware-owned graph state schema entries."
  @spec state_schema(t()) :: map() | nil
  defdelegate state_schema(middleware), to: Capabilities

  @doc "Returns middleware-required runtime context schema entries."
  @spec context_schema(t()) :: map() | nil
  defdelegate context_schema(middleware), to: Capabilities

  @doc "Returns tools contributed by middleware."
  @spec tools(t()) :: [term()]
  defdelegate tools(middleware), to: Capabilities

  @doc "Returns whether middleware requires the agent tool node."
  @spec tool_node_required?(t()) :: boolean()
  defdelegate tool_node_required?(middleware), to: Capabilities

  @doc "Returns jump targets a middleware hook may route to."
  @spec can_jump_to(t(), atom()) :: [:model | :tools | :end]
  defdelegate can_jump_to(middleware, hook), to: Capabilities

  @doc "Returns whether middleware requires a checkpointer."
  @spec requires_checkpointer?(t()) :: boolean()
  defdelegate requires_checkpointer?(middleware), to: Capabilities
end
