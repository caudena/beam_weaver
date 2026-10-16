defmodule BeamWeaver.Agent.Middleware do
  @moduledoc ~S"""
  Behaviour for agent middleware.

  `use BeamWeaver.Agent.Middleware` and define any of the hooks. Every callback
  receives the middleware itself first: the struct for struct middleware, or
  the module for module middleware.

      defmodule MyApp.LogMiddleware do
        use BeamWeaver.Agent.Middleware

        def before_model(_middleware, state, _runtime) do
          Logger.info("calling the model with #{length(state.messages)} messages")
          nil
        end
      end

  An agent's middleware entry can be a module, a struct, or `{module, opts}`.
  `{module, opts}` is built with `module.new(opts)` when the module defines
  `new/1`, and with `struct!/2` when it defines a struct. A bare module is
  built the same way with no options, so `MyApp.Limit` and `{MyApp.Limit, []}`
  are the same entry; a module without `new/1` or a struct is used as is.
  `name/1`, `state_schema/1`, `context_schema/1`, `tools/1`, and
  `requires_checkpointer?/1` have defaults that a middleware can override.
  """

  alias BeamWeaver.Agent.Middleware.Hooks
  alias BeamWeaver.Core.Error

  @type t :: module() | struct()
  @type hook :: :before_agent | :before_model | :after_model | :after_agent | :wrap_model_call | :wrap_tool_call
  @type jump_target :: :model | :tools | :end
  @type hook_result ::
          nil
          | map()
          | {:ok, map()}
          | {:error, term()}
          | {:jump, jump_target(), map()}
          | BeamWeaver.Graph.Command.t()

  @callback name(t()) :: atom() | String.t()
  @callback state_schema(t()) :: map() | nil
  @callback context_schema(t()) :: map() | nil
  @callback tools(t()) :: [term()]
  @callback requires_checkpointer?(t()) :: boolean()
  @callback before_agent(t(), state :: map(), BeamWeaver.Graph.Runtime.t()) :: hook_result()
  @callback before_model(t(), state :: map(), BeamWeaver.Graph.Runtime.t()) :: hook_result()
  @callback after_model(t(), state :: map(), BeamWeaver.Graph.Runtime.t()) :: hook_result()
  @callback after_agent(t(), state :: map(), BeamWeaver.Graph.Runtime.t()) :: hook_result()
  @callback wrap_model_call(t(), BeamWeaver.Agent.ModelRequest.t(), handler :: function()) :: term()
  @callback wrap_tool_call(t(), BeamWeaver.Agent.ToolCallRequest.t(), handler :: function()) :: term()

  @optional_callbacks before_agent: 3,
                      before_model: 3,
                      after_model: 3,
                      after_agent: 3,
                      wrap_model_call: 3,
                      wrap_tool_call: 3

  @hooks [:before_agent, :before_model, :after_model, :after_agent, :wrap_model_call, :wrap_tool_call]

  defmacro __using__(_opts) do
    quote do
      @behaviour BeamWeaver.Agent.Middleware
      @before_compile BeamWeaver.Agent.Middleware

      @doc false
      def name(middleware), do: BeamWeaver.Agent.Middleware.default_name(middleware)
      @doc false
      def state_schema(_middleware), do: nil
      @doc false
      def context_schema(_middleware), do: nil
      @doc false
      def tools(_middleware), do: []
      @doc false
      def requires_checkpointer?(_middleware), do: false

      defoverridable name: 1,
                     state_schema: 1,
                     context_schema: 1,
                     tools: 1,
                     requires_checkpointer?: 1
    end
  end

  defmacro __before_compile__(env) do
    hooks = Enum.filter(@hooks, &Module.defines?(env.module, {&1, 3}, :def))

    quote do
      @doc false
      def __middleware_hooks__, do: unquote(hooks)
    end
  end

  @doc false
  def default_name(module) when is_atom(module), do: inspect(module)
  def default_name(%module{}), do: module |> Module.split() |> List.last()

  @doc "Normalizes a middleware entry into a module or struct."
  @spec normalize(term()) :: {:ok, t()} | {:error, Error.t()}
  def normalize({module, opts}) when is_atom(module) and is_list(opts) do
    if middleware_module?(module), do: build(module, opts), else: not_middleware(module)
  end

  def normalize(module) when is_atom(module) do
    if middleware_module?(module), do: build(module, []), else: not_middleware(module)
  end

  def normalize(%module{} = middleware) do
    if middleware_module?(module), do: {:ok, middleware}, else: not_middleware(module)
  end

  def normalize(other) do
    {:error,
     Error.new(:invalid_middleware, "middleware must be a module, struct, or {module, opts}", %{
       middleware: inspect(other)
     })}
  end

  @doc "Normalizes a list of middleware entries."
  @spec normalize_all([term()]) :: {:ok, [t()]} | {:error, Error.t()}
  def normalize_all(entries) do
    entries
    |> List.wrap()
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      case normalize(entry) do
        {:ok, middleware} -> {:cont, {:ok, [middleware | acc]}}
        {:error, _error} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, middleware} -> {:ok, Enum.reverse(middleware)}
      error -> error
    end
  end

  @doc "Returns the stable middleware name."
  @spec name(t()) :: String.t()
  def name(middleware), do: to_string(module(middleware).name(middleware))

  @doc false
  @spec hook?(t(), atom()) :: boolean()
  def hook?(middleware, hook), do: hook in module(middleware).__middleware_hooks__()

  @doc false
  @spec call_hook(t(), atom(), map(), BeamWeaver.Graph.Runtime.t()) :: hook_result()
  def call_hook(middleware, hook, state, runtime)
      when hook in [:before_agent, :before_model, :after_model, :after_agent],
      do: Hooks.call(middleware, hook, state, runtime)

  @doc false
  @spec call_wrapper(t(), :wrap_model_call | :wrap_tool_call, term(), function()) :: term()
  def call_wrapper(middleware, hook, request, handler) when hook in [:wrap_model_call, :wrap_tool_call],
    do: Hooks.call(middleware, hook, request, handler)

  @doc "Returns middleware-owned graph state schema entries."
  @spec state_schema(t()) :: map() | nil
  def state_schema(middleware), do: module(middleware).state_schema(middleware)

  @doc "Returns middleware-required runtime context schema entries."
  @spec context_schema(t()) :: map() | nil
  def context_schema(middleware), do: module(middleware).context_schema(middleware)

  @doc "Returns tools contributed by middleware."
  @spec tools(t()) :: [term()]
  def tools(middleware), do: module(middleware).tools(middleware) || []

  @doc "Returns whether middleware requires a checkpointer."
  @spec requires_checkpointer?(t()) :: boolean()
  def requires_checkpointer?(middleware), do: module(middleware).requires_checkpointer?(middleware) == true

  defp module(%module{}), do: module
  defp module(module) when is_atom(module), do: module

  defp build(module, opts) do
    cond do
      function_exported?(module, :new, 1) -> {:ok, module.new(opts)}
      function_exported?(module, :__struct__, 0) -> {:ok, struct!(module, opts)}
      opts == [] -> {:ok, module}
      true -> {:error, Error.new(:invalid_middleware, "middleware module takes no options", %{module: inspect(module)})}
    end
  rescue
    # A constructor raises for options it can't take.
    error in [ArgumentError, KeyError] ->
      {:error, Error.new(:invalid_middleware, "#{inspect(module)}: #{option_error(error)}", %{module: inspect(module)})}
  end

  @doc false
  # The message of an error that a constructor raised for its options. The
  # message of a `KeyError` from `Keyword.fetch!/2` shows every option, an
  # API key among them, so only its key is kept.
  @spec option_error(Exception.t()) :: String.t()
  def option_error(%KeyError{key: key}), do: "key #{inspect(key)} not found"
  def option_error(exception), do: Exception.message(exception)

  defp middleware_module?(module),
    do: Code.ensure_loaded?(module) and function_exported?(module, :__middleware_hooks__, 0)

  defp not_middleware(module) do
    {:error,
     Error.new(:invalid_middleware, "#{inspect(module)} does not `use BeamWeaver.Agent.Middleware`", %{
       module: inspect(module)
     })}
  end
end
