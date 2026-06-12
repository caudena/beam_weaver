defmodule BeamWeaver.Agent.Middleware.Normalize do
  @moduledoc false

  alias BeamWeaver.Core.Error

  @type middleware :: module() | struct()

  @spec normalize(term()) :: {:ok, middleware()} | {:error, Error.t()}
  def normalize({module, opts}) when is_atom(module) and is_list(opts) do
    Code.ensure_loaded?(module)

    cond do
      function_exported?(module, :new, 1) ->
        {:ok, module.new(opts)}

      function_exported?(module, :new, 0) and opts == [] ->
        {:ok, module.new()}

      function_exported?(module, :__struct__, 0) ->
        {:ok, struct(module, opts)}

      opts == [] ->
        {:ok, module}

      true ->
        {:error,
         Error.new(:invalid_middleware, "middleware module cannot be initialized with opts", %{
           module: inspect(module)
         })}
    end
  end

  def normalize(module) when is_atom(module) do
    Code.ensure_loaded?(module)

    cond do
      function_exported?(module, :new, 0) ->
        {:ok, module.new()}

      function_exported?(module, :new, 1) ->
        {:ok, module.new([])}

      true ->
        {:ok, module}
    end
  end

  def normalize(%{__struct__: _module} = middleware), do: {:ok, middleware}

  def normalize(other) do
    {:error,
     Error.new(:invalid_middleware, "middleware must be a module, struct, or {module, opts}", %{
       middleware: inspect(other)
     })}
  end

  @spec normalize_all([term()]) :: {:ok, [middleware()]} | {:error, Error.t()}
  def normalize_all(entries) do
    entries
    |> List.wrap()
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      case normalize(entry) do
        {:ok, middleware} -> {:cont, {:ok, [middleware | acc]}}
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, middleware} -> {:ok, Enum.reverse(middleware)}
      {:error, %Error{} = error} -> {:error, error}
    end
  end
end
